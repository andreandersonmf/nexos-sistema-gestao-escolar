def analisar_risco(frequencia, media):
    if frequencia < 75 and media < 6:
        return "Alto risco acadêmico"
    return "Baixo risco acadêmico"