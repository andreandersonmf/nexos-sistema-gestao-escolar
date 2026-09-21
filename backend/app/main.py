from fastapi import FastAPI

app = FastAPI(title="Nexo's API")

@app.get("/")
def home():
    return {"sistema": "Nexo's", "status": "online"}