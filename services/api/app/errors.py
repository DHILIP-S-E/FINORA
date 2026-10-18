from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict | None = None):
        self.status, self.code, self.message, self.details = status, code, message, details or {}


def NotFound(what: str = "resource") -> ApiError:  # noqa: N802
    return ApiError(404, "not_found", f"{what} not found")


def body(code: str, message: str, details: dict | None = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api(_: Request, e: ApiError):
        headers = {"Retry-After": "30"} if e.status == 429 else None
        return JSONResponse(body(e.code, e.message, e.details), status_code=e.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def _val(_: Request, e: RequestValidationError):
        errs = [{"loc": list(x["loc"]), "msg": x["msg"]} for x in e.errors()]  # no input echo (may be financial)
        return JSONResponse(body("validation_error", "Request validation failed", {"errors": errs}), status_code=422)

    @app.exception_handler(Exception)
    async def _any(_: Request, e: Exception):
        import logging
        logging.getLogger("cascade").error("unhandled %s", type(e).__name__)
        return JSONResponse(body("internal_error", "Unexpected server error"), status_code=500)
