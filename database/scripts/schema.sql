-- =====================================================================
--  NEXO'S - SISTEMA DE GESTÃO ESCOLAR
--  Schema do banco de dados (PostgreSQL 13+)
--
--  Como executar (em um banco VAZIO):
--      createdb nexos
--      psql -d nexos -f schema.sql
--
--  Organização deste arquivo:
--    0. Funções utilitárias
--    1. Usuários e perfis de acesso
--    2. Pessoas (aluno, responsável, professor, coordenador)
--    3. Estrutura acadêmica (ano letivo, período, turma, disciplina)
--    4. Matrícula
--    5. Avaliação: notas e frequência
--    6. Comunicação e ocorrências
--    7. Nexo IA (análise de risco e alertas)
--    8. Auditoria (LGPD)
--    9. Views (consultas prontas para API e IA)
-- =====================================================================


-- =====================================================================
-- 0. FUNÇÕES UTILITÁRIAS
-- =====================================================================

-- Atualiza automaticamente a coluna atualizado_em a cada UPDATE.
CREATE OR REPLACE FUNCTION fn_atualiza_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.atualizado_em = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =====================================================================
-- 1. USUÁRIOS E PERFIS DE ACESSO
-- =====================================================================

-- Conta de login do sistema. Cada pessoa (aluno, responsável, professor,
-- coordenador) pode ter uma conta vinculada pela coluna usuario_id.
CREATE TABLE usuario (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email           VARCHAR(150) NOT NULL UNIQUE,
    senha_hash      VARCHAR(255) NOT NULL,      -- NUNCA guardar senha pura (use bcrypt/argon2)
    perfil          VARCHAR(20)  NOT NULL
                    CHECK (perfil IN ('aluno', 'responsavel', 'professor', 'coordenacao', 'admin')),
    ativo           BOOLEAN      NOT NULL DEFAULT TRUE,
    ultimo_acesso   TIMESTAMPTZ,
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- =====================================================================
-- 2. PESSOAS
-- =====================================================================

-- ALUNO: mantém as colunas originais (id, nome, data_nascimento, status)
-- e ganha novas informações.
CREATE TABLE aluno (
    id                INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id        INTEGER UNIQUE REFERENCES usuario(id) ON DELETE SET NULL,
    numero_matricula  VARCHAR(20) UNIQUE,        -- número/RA institucional do aluno
    nome              VARCHAR(100) NOT NULL,
    data_nascimento   DATE         NOT NULL,
    cpf               CHAR(11)     UNIQUE,       -- opcional (menores podem não ter)
    sexo              CHAR(1)      CHECK (sexo IN ('M', 'F', 'O')),
    email             VARCHAR(150),
    telefone          VARCHAR(20),
    endereco          VARCHAR(255),
    necessidades_especiais TEXT,                 -- dado sensível (LGPD): restringir acesso
    status            VARCHAR(20)  NOT NULL DEFAULT 'ativo'
                      CHECK (status IN ('ativo', 'inativo', 'transferido', 'concluido')),
    criado_em         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_aluno_nascimento CHECK (data_nascimento <= CURRENT_DATE)
);

CREATE TABLE responsavel (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id      INTEGER UNIQUE REFERENCES usuario(id) ON DELETE SET NULL,
    nome            VARCHAR(100) NOT NULL,
    cpf             CHAR(11)     UNIQUE,
    email           VARCHAR(150),
    telefone        VARCHAR(20),
    profissao       VARCHAR(100),
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Relação N:N: um aluno pode ter vários responsáveis e um responsável
-- pode ter vários filhos/dependentes na escola.
CREATE TABLE aluno_responsavel (
    aluno_id                INTEGER NOT NULL REFERENCES aluno(id)       ON DELETE CASCADE,
    responsavel_id          INTEGER NOT NULL REFERENCES responsavel(id) ON DELETE CASCADE,
    parentesco              VARCHAR(30) NOT NULL,          -- mãe, pai, avó, tutor...
    responsavel_financeiro  BOOLEAN NOT NULL DEFAULT FALSE,
    contato_emergencia      BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (aluno_id, responsavel_id)
);

CREATE TABLE professor (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id      INTEGER UNIQUE REFERENCES usuario(id) ON DELETE SET NULL,
    nome            VARCHAR(100) NOT NULL,
    cpf             CHAR(11)     UNIQUE,
    email           VARCHAR(150),
    telefone        VARCHAR(20),
    formacao        VARCHAR(150),
    status          VARCHAR(20)  NOT NULL DEFAULT 'ativo'
                    CHECK (status IN ('ativo', 'inativo', 'afastado')),
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE coordenador (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id      INTEGER UNIQUE REFERENCES usuario(id) ON DELETE SET NULL,
    nome            VARCHAR(100) NOT NULL,
    cpf             CHAR(11)     UNIQUE,
    email           VARCHAR(150),
    telefone        VARCHAR(20),
    cargo           VARCHAR(60),                  -- coordenador pedagógico, diretor, orientador...
    status          VARCHAR(20)  NOT NULL DEFAULT 'ativo'
                    CHECK (status IN ('ativo', 'inativo')),
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- =====================================================================
-- 3. ESTRUTURA ACADÊMICA
-- =====================================================================

CREATE TABLE ano_letivo (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano             SMALLINT NOT NULL UNIQUE,
    data_inicio     DATE     NOT NULL,
    data_fim        DATE     NOT NULL,
    ativo           BOOLEAN  NOT NULL DEFAULT FALSE,
    CONSTRAINT ck_ano_letivo_datas CHECK (data_fim > data_inicio)
);

-- Garante que exista no máximo UM ano letivo ativo por vez.
CREATE UNIQUE INDEX uq_ano_letivo_unico_ativo ON ano_letivo (ativo) WHERE ativo;

-- Bimestres, trimestres ou semestres (as notas são lançadas por período).
CREATE TABLE periodo_letivo (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano_letivo_id   INTEGER  NOT NULL REFERENCES ano_letivo(id) ON DELETE CASCADE,
    numero          SMALLINT NOT NULL CHECK (numero > 0),
    nome            VARCHAR(30) NOT NULL,          -- ex.: '1º Bimestre'
    data_inicio     DATE     NOT NULL,
    data_fim        DATE     NOT NULL,
    UNIQUE (ano_letivo_id, numero),
    CONSTRAINT ck_periodo_datas CHECK (data_fim > data_inicio)
);

-- TURMA: ex. "7A". O campo "nome" corresponde ao que a rota /alunos já retorna.
CREATE TABLE turma (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano_letivo_id   INTEGER  NOT NULL REFERENCES ano_letivo(id) ON DELETE RESTRICT,
    nome            VARCHAR(20) NOT NULL,          -- ex.: '7A'
    serie           VARCHAR(30) NOT NULL,          -- ex.: '7º ano'
    turno           VARCHAR(10) NOT NULL
                    CHECK (turno IN ('manha', 'tarde', 'noite', 'integral')),
    capacidade      SMALLINT CHECK (capacidade > 0),
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (ano_letivo_id, nome)
);

CREATE TABLE disciplina (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome            VARCHAR(80) NOT NULL UNIQUE,
    carga_horaria   SMALLINT CHECK (carga_horaria > 0)
);

-- Liga turma + disciplina + professor. É a "oferta" da disciplina na turma.
-- (ex.: Matemática na turma 7A, ministrada pelo prof. João)
CREATE TABLE turma_disciplina (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    turma_id        INTEGER NOT NULL REFERENCES turma(id)      ON DELETE CASCADE,
    disciplina_id   INTEGER NOT NULL REFERENCES disciplina(id) ON DELETE RESTRICT,
    professor_id    INTEGER NOT NULL REFERENCES professor(id)  ON DELETE RESTRICT,
    UNIQUE (turma_id, disciplina_id)
);


-- =====================================================================
-- 4. MATRÍCULA
-- =====================================================================

-- Vincula o aluno a uma turma (e, por consequência, a um ano letivo).
-- Notas e frequência referenciam a MATRÍCULA, preservando o histórico
-- caso o aluno mude de turma ou de ano.
CREATE TABLE matricula (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aluno_id        INTEGER NOT NULL REFERENCES aluno(id) ON DELETE RESTRICT,
    turma_id        INTEGER NOT NULL REFERENCES turma(id) ON DELETE RESTRICT,
    data_matricula  DATE    NOT NULL DEFAULT CURRENT_DATE,
    data_saida      DATE,
    status          VARCHAR(20) NOT NULL DEFAULT 'ativa'
                    CHECK (status IN ('ativa', 'trancada', 'transferida', 'cancelada', 'concluida')),
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (aluno_id, turma_id),
    CONSTRAINT ck_matricula_datas CHECK (data_saida IS NULL OR data_saida >= data_matricula)
);

-- Um aluno só pode ter UMA matrícula ativa por vez.
CREATE UNIQUE INDEX uq_matricula_ativa_por_aluno ON matricula (aluno_id) WHERE status = 'ativa';


-- =====================================================================
-- 5. AVALIAÇÃO: NOTAS E FREQUÊNCIA
-- =====================================================================

-- Uma avaliação (prova, trabalho...) aplicada em uma disciplina/turma
-- dentro de um período.
CREATE TABLE avaliacao (
    id                   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    turma_disciplina_id  INTEGER NOT NULL REFERENCES turma_disciplina(id) ON DELETE CASCADE,
    periodo_id           INTEGER NOT NULL REFERENCES periodo_letivo(id)   ON DELETE RESTRICT,
    titulo               VARCHAR(100) NOT NULL,
    tipo                 VARCHAR(20)  NOT NULL
                         CHECK (tipo IN ('prova', 'trabalho', 'atividade', 'recuperacao', 'outro')),
    data_aplicacao       DATE,
    peso                 NUMERIC(4,2) NOT NULL DEFAULT 1 CHECK (peso > 0),
    nota_maxima          NUMERIC(5,2) NOT NULL DEFAULT 10 CHECK (nota_maxima > 0),
    criado_em            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Nota de cada aluno (via matrícula) em cada avaliação.
CREATE TABLE nota (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    avaliacao_id    INTEGER NOT NULL REFERENCES avaliacao(id) ON DELETE CASCADE,
    matricula_id    INTEGER NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
    valor           NUMERIC(5,2) NOT NULL CHECK (valor >= 0),
    observacao      VARCHAR(255),
    lancado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (avaliacao_id, matricula_id)
);

-- Impede lançar nota maior que a nota máxima da avaliação.
CREATE OR REPLACE FUNCTION fn_valida_nota_maxima()
RETURNS TRIGGER AS $$
DECLARE
    v_max NUMERIC;
BEGIN
    SELECT nota_maxima INTO v_max FROM avaliacao WHERE id = NEW.avaliacao_id;
    IF NEW.valor > v_max THEN
        RAISE EXCEPTION 'Nota % maior que a nota máxima (%) da avaliação %',
            NEW.valor, v_max, NEW.avaliacao_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_nota_valida_maxima
    BEFORE INSERT OR UPDATE ON nota
    FOR EACH ROW EXECUTE FUNCTION fn_valida_nota_maxima();

-- Aula ministrada (dia em que a chamada é feita).
CREATE TABLE aula (
    id                   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    turma_disciplina_id  INTEGER NOT NULL REFERENCES turma_disciplina(id) ON DELETE CASCADE,
    data_aula            DATE    NOT NULL,
    conteudo             TEXT,
    UNIQUE (turma_disciplina_id, data_aula)
);

-- Chamada: uma linha por aluno por aula.
CREATE TABLE frequencia (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aula_id         INTEGER NOT NULL REFERENCES aula(id)      ON DELETE CASCADE,
    matricula_id    INTEGER NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
    situacao        VARCHAR(20) NOT NULL
                    CHECK (situacao IN ('presente', 'falta', 'falta_justificada')),
    justificativa   VARCHAR(255),
    UNIQUE (aula_id, matricula_id)
);


-- =====================================================================
-- 6. COMUNICAÇÃO E OCORRÊNCIAS
-- =====================================================================

-- Comunicados da escola. Se turma_id for NULL, vale para toda a escola.
CREATE TABLE comunicado (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    autor_id        INTEGER NOT NULL REFERENCES usuario(id) ON DELETE RESTRICT,
    turma_id        INTEGER REFERENCES turma(id) ON DELETE CASCADE,
    titulo          VARCHAR(150) NOT NULL,
    mensagem        TEXT         NOT NULL,
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Registros disciplinares ou pedagógicos sobre o aluno.
CREATE TABLE ocorrencia (
    id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula_id    INTEGER NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
    registrado_por  INTEGER NOT NULL REFERENCES usuario(id)   ON DELETE RESTRICT,
    tipo            VARCHAR(20) NOT NULL
                    CHECK (tipo IN ('disciplinar', 'pedagogica', 'saude', 'elogio', 'outro')),
    descricao       TEXT        NOT NULL,
    data_ocorrencia DATE        NOT NULL DEFAULT CURRENT_DATE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =====================================================================
-- 7. NEXO IA: ANÁLISE DE RISCO E ALERTAS
-- =====================================================================

-- Resultado de cada execução do módulo de IA para uma matrícula.
-- Guardar o histórico permite ver a EVOLUÇÃO do risco ao longo do ano.
CREATE TABLE analise_risco (
    id                     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula_id           INTEGER NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
    periodo_id             INTEGER REFERENCES periodo_letivo(id) ON DELETE SET NULL,
    frequencia_percentual  NUMERIC(5,2) CHECK (frequencia_percentual BETWEEN 0 AND 100),
    media_geral            NUMERIC(4,2) CHECK (media_geral BETWEEN 0 AND 10),
    score_risco            NUMERIC(5,2) CHECK (score_risco BETWEEN 0 AND 100),
    nivel_risco            VARCHAR(10) NOT NULL
                           CHECK (nivel_risco IN ('baixo', 'medio', 'alto')),
    motivos                JSONB,                      -- explicação: fatores que geraram o risco
    versao_modelo          VARCHAR(30),                -- rastreia qual regra/modelo gerou o resultado
    gerado_em              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Alerta para a coordenação/professores/responsáveis agirem.
CREATE TABLE alerta (
    id                INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    analise_risco_id  INTEGER REFERENCES analise_risco(id) ON DELETE SET NULL,
    matricula_id      INTEGER NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
    mensagem          TEXT NOT NULL,
    status            VARCHAR(20) NOT NULL DEFAULT 'aberto'
                      CHECK (status IN ('aberto', 'em_acompanhamento', 'resolvido', 'descartado')),
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolvido_em      TIMESTAMPTZ,
    resolvido_por     INTEGER REFERENCES usuario(id) ON DELETE SET NULL
);


-- =====================================================================
-- 8. AUDITORIA (LGPD)
-- =====================================================================

-- Registra quem acessou/alterou dados sensíveis (dados de menores de idade).
CREATE TABLE log_auditoria (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id      INTEGER REFERENCES usuario(id) ON DELETE SET NULL,
    acao            VARCHAR(20) NOT NULL
                    CHECK (acao IN ('login', 'consulta', 'criacao', 'alteracao', 'exclusao')),
    tabela          VARCHAR(60),
    registro_id     INTEGER,
    detalhes        JSONB,
    ip              INET,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =====================================================================
-- TRIGGERS DE atualizado_em
-- =====================================================================
CREATE TRIGGER trg_usuario_upd      BEFORE UPDATE ON usuario      FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_aluno_upd        BEFORE UPDATE ON aluno        FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_responsavel_upd  BEFORE UPDATE ON responsavel  FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_professor_upd    BEFORE UPDATE ON professor    FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_coordenador_upd  BEFORE UPDATE ON coordenador  FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_turma_upd        BEFORE UPDATE ON turma        FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();
CREATE TRIGGER trg_matricula_upd    BEFORE UPDATE ON matricula    FOR EACH ROW EXECUTE FUNCTION fn_atualiza_timestamp();


-- =====================================================================
-- ÍNDICES (chaves estrangeiras e consultas frequentes)
-- =====================================================================
CREATE INDEX idx_aluno_nome            ON aluno (nome);
CREATE INDEX idx_aluno_status          ON aluno (status);
CREATE INDEX idx_aluno_resp_resp       ON aluno_responsavel (responsavel_id);
CREATE INDEX idx_periodo_ano           ON periodo_letivo (ano_letivo_id);
CREATE INDEX idx_turma_ano             ON turma (ano_letivo_id);
CREATE INDEX idx_turma_disc_prof       ON turma_disciplina (professor_id);
CREATE INDEX idx_turma_disc_disc       ON turma_disciplina (disciplina_id);
CREATE INDEX idx_matricula_turma       ON matricula (turma_id);
CREATE INDEX idx_avaliacao_td          ON avaliacao (turma_disciplina_id);
CREATE INDEX idx_avaliacao_periodo     ON avaliacao (periodo_id);
CREATE INDEX idx_nota_matricula        ON nota (matricula_id);
CREATE INDEX idx_aula_td_data          ON aula (turma_disciplina_id, data_aula);
CREATE INDEX idx_frequencia_matricula  ON frequencia (matricula_id);
CREATE INDEX idx_comunicado_turma      ON comunicado (turma_id);
CREATE INDEX idx_ocorrencia_matricula  ON ocorrencia (matricula_id);
CREATE INDEX idx_analise_matricula     ON analise_risco (matricula_id, gerado_em DESC);
CREATE INDEX idx_alerta_status         ON alerta (status);
CREATE INDEX idx_alerta_matricula      ON alerta (matricula_id);
CREATE INDEX idx_auditoria_usuario     ON log_auditoria (usuario_id, criado_em DESC);


-- =====================================================================
-- 9. VIEWS
-- =====================================================================

-- Lista alunos com a turma atual. Atende diretamente a rota GET /alunos
-- (que hoje devolve nome + turma).
CREATE VIEW vw_aluno_turma AS
SELECT
    a.id            AS aluno_id,
    a.nome,
    a.status        AS status_aluno,
    m.id            AS matricula_id,
    t.nome          AS turma,
    t.serie,
    t.turno,
    al.ano          AS ano_letivo
FROM aluno a
LEFT JOIN matricula   m  ON m.aluno_id = a.id AND m.status = 'ativa'
LEFT JOIN turma       t  ON t.id = m.turma_id
LEFT JOIN ano_letivo  al ON al.id = t.ano_letivo_id;

-- Percentual de frequência por matrícula (faltas justificadas contam como
-- ausência na conta; ajuste aqui se a escola tratar de outra forma).
CREATE VIEW vw_frequencia_matricula AS
SELECT
    f.matricula_id,
    COUNT(*)                                            AS total_aulas,
    COUNT(*) FILTER (WHERE f.situacao = 'presente')     AS presencas,
    COUNT(*) FILTER (WHERE f.situacao <> 'presente')    AS faltas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.situacao = 'presente') / COUNT(*), 2)
                                                        AS frequencia_percentual
FROM frequencia f
GROUP BY f.matricula_id;

-- Média ponderada por disciplina, já normalizada para escala 0-10
-- (nota / nota_maxima * 10), considerando o peso de cada avaliação.
CREATE VIEW vw_media_disciplina AS
SELECT
    n.matricula_id,
    av.turma_disciplina_id,
    ROUND(SUM((n.valor / av.nota_maxima) * 10 * av.peso) / SUM(av.peso), 2) AS media
FROM nota n
JOIN avaliacao av ON av.id = n.avaliacao_id
GROUP BY n.matricula_id, av.turma_disciplina_id;

-- Visão consolidada de desempenho: é a ENTRADA do módulo Nexo IA
-- (frequência + média geral) para cada matrícula ativa.
CREATE VIEW vw_desempenho_aluno AS
SELECT
    m.id                          AS matricula_id,
    a.id                          AS aluno_id,
    a.nome                        AS aluno,
    t.nome                        AS turma,
    fm.frequencia_percentual,
    ROUND(AVG(md.media), 2)       AS media_geral
FROM matricula m
JOIN aluno a                  ON a.id = m.aluno_id
JOIN turma t                  ON t.id = m.turma_id
LEFT JOIN vw_frequencia_matricula fm ON fm.matricula_id = m.id
LEFT JOIN vw_media_disciplina     md ON md.matricula_id = m.id
WHERE m.status = 'ativa'
GROUP BY m.id, a.id, a.nome, t.nome, fm.frequencia_percentual;