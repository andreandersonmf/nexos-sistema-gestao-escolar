from fastapi import APIRouter

router = APIRouter()

@router.get("/alunos")
def listar_alunos():
    return [{"nome": "Ana", "turma": "7A"}]