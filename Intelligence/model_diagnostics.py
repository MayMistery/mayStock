"""Classify SDK failures without exposing provider prose or connection secrets.

Provider messages are inspected only to recognize narrowly defined model error
identifiers. Public diagnostics are rebuilt from fixed templates and allowlists;
raw result/errors/stderr and exception strings never enter the returned values.
"""
from __future__ import annotations

import re

if __package__:
    from .research import ResearchError
else:
    from research import ResearchError


MESSAGES = {
    "AUTH_REQUIRED": "模型服务未接受本次请求的认证；已保留上次结果。",
    "MODEL_ACCESS_DENIED": "模型服务拒绝了本次请求的访问权限；已保留上次结果。",
    "MODEL_RATE_LIMIT": "模型服务限流或可用额度受限；请稍后重试，已保留上次结果。",
    "MODEL_UPSTREAM_UNAVAILABLE": "模型服务或中转服务暂时异常；请稍后重试，已保留上次结果。",
    "MODEL_REQUEST_REJECTED": "模型服务拒绝了请求参数或模型访问请求；仅凭此错误无法区分模型映射、访问权限或路由问题。已保留上次结果。",
    "MODEL_UNAVAILABLE": "模型服务明确返回 model_not_found，未识别请求的模型；已保留上次结果。",
    "MODEL_FAILED": "Claude SDK 未完成本次模型调用，现有信息不足以确定原因；已保留上次结果。",
}
ASSISTANT_ERRORS = {
    "authentication_failed": "AUTH_REQUIRED",
    "billing_error": "MODEL_RATE_LIMIT",
    "rate_limit": "MODEL_RATE_LIMIT",
    "invalid_request": "MODEL_REQUEST_REJECTED",
    "server_error": "MODEL_UPSTREAM_UNAVAILABLE",
    "unknown": "MODEL_FAILED",
}
SDK_CLASSES = {
    "ResultMessage", "AssistantMessage", "ResultError", "ProcessError",
    "CLIConnectionError", "CLINotFoundError", "CLIJSONDecodeError", "MessageParseError",
    "ClaudeSDKError", "TimeoutError", "ConnectionError",
}
SUBTYPES = {
    "success", "error_during_execution", "error_max_turns", "error_max_budget_usd",
    "error_max_structured_output_retries",
}
TERMINAL_REASONS = {
    "api_error", "max_turns", "max_budget_usd", "max_structured_output_retries",
    "structured_output_retries", "completed", "cancelled", "interrupted",
}
MODEL_NOT_FOUND = re.compile(r"(?<![a-z0-9_])model_not_found(?![a-z0-9_])", re.I)
AMBIGUOUS_MODEL = re.compile(r"\bselected\s+model\b", re.I)


def _field(message, name):
    try:
        return getattr(message, name, None)
    except Exception:
        return None


def _enum(value, allowed):
    return value if isinstance(value, str) and value in allowed else None


def _text_fields(message):
    """Internal classification only; callers never receive these strings."""
    result = _field(message, "result")
    if isinstance(result, str):
        yield result
    errors = _field(message, "errors")
    if isinstance(errors, (list, tuple)):
        yield from (value for value in errors if isinstance(value, str))


def model_error_fields(message=None, assistant_error=None) -> dict:
    """Return only fixed classifications, legal HTTP integers and known enums."""
    raw_status = _field(message, "api_error_status")
    status = raw_status if isinstance(raw_status, int) and not isinstance(raw_status, bool) and 100 <= raw_status <= 599 else None
    assistant = _enum(assistant_error, ASSISTANT_ERRORS)
    if assistant is None:
        assistant = _enum(_field(message, "error"), ASSISTANT_ERRORS)
    error_class = type(message).__name__ if message is not None else None
    error_class = error_class if error_class in SDK_CLASSES else "unknown" if message is not None else None
    fields = {
        "code": "MODEL_FAILED", "evidence": "unclassified", "apiStatus": status,
        "errorClass": error_class,
        "subtype": _enum(_field(message, "subtype"), SUBTYPES),
        "terminalReason": _enum(_field(message, "terminal_reason"), TERMINAL_REASONS),
        "assistantError": assistant,
    }
    # Structured provider status takes priority over both wrapper prose and a
    # remembered AssistantMessage error from an earlier message in the stream.
    status_codes = {401: "AUTH_REQUIRED", 403: "MODEL_ACCESS_DENIED",
                    429: "MODEL_RATE_LIMIT", 400: "MODEL_REQUEST_REJECTED"}
    if status in status_codes or status is not None and status >= 500:
        fields.update(code=status_codes.get(status, "MODEL_UPSTREAM_UNAVAILABLE"), evidence="http_status")
        return fields
    if assistant is not None and assistant != "unknown":
        fields.update(code=ASSISTANT_ERRORS[assistant], evidence="assistant_error")
        return fields
    texts = tuple(_text_fields(message))
    if any(MODEL_NOT_FOUND.search(text) for text in texts):
        fields.update(code="MODEL_UNAVAILABLE", evidence="model_error_code")
    elif status is not None and 400 <= status < 500:
        fields.update(code="MODEL_REQUEST_REJECTED", evidence="http_status")
    elif any(AMBIGUOUS_MODEL.search(text) for text in texts):
        fields.update(code="MODEL_REQUEST_REJECTED", evidence="ambiguous_model_access")
    return fields


def model_error(message=None, assistant_error=None) -> ResearchError:
    fields = model_error_fields(message, assistant_error)
    return ResearchError(fields["code"] + ": " + MESSAGES[fields["code"]])
