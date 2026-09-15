"""Wire schema shared with the Swift models (see docs/INTELLIGENCE-CONTRACT.md)."""

import copy

def obj(properties):
    return {"type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False}


def enum(*values):
    return {"type": "string", "enum": list(values)}


STRING = {"type": "string"}
NUMBER = {"type": "number"}
NULLABLE_NUMBER = {"type": ["number", "null"]}
STRINGS = {"type": "array", "items": STRING}
SOURCE = obj({"title": STRING, "url": STRING, "publisher": STRING,
              "retrievedAt": NUMBER, "evidence": STRING})
EVENT = obj({
    "id": STRING, "title": STRING,
    "category": enum("macro", "policy", "geopolitics", "crypto", "earnings"),
    "importance": enum("high", "medium", "low"),
    "status": enum("scheduled", "occurred", "unverified"),
    "occurredAt": NUMBER, "timePrecision": enum("minute", "day", "unknown"),
    "publishedAt": NULLABLE_NUMBER, "summary": STRING, "impact": STRING,
    "sources": {"type": "array", "items": SOURCE, "minItems": 1, "maxItems": 5},
})
PREDICTION = obj({
    "instId": STRING, "direction": enum("up", "down", "neutral", "insufficient"),
    "confidence": enum("low", "medium", "high"), "horizonHours": NUMBER,
    "generatedAt": NUMBER, "referencePrice": NULLABLE_NUMBER,
    "drivers": STRINGS, "invalidation": STRING, "eventIds": STRINGS,
})
FINDING = obj({
    "id": STRING, "title": STRING, "body": STRING,
    "kind": enum("observation", "inference", "unknown"),
    "instIds": STRINGS,
    "sources": {"type": "array", "items": SOURCE, "maxItems": 5},
})
# Existing archived reports can omit these fields. New model responses must
# explicitly separate evidence/context from newly occurred calendar events.
PREDICTION["properties"]["findingIds"] = STRINGS
REPORT_SCHEMA = obj({
    "id": STRING, "kind": enum("daily", "hourly", "flash"),
    "generatedAt": NUMBER, "windowStart": NUMBER, "windowEnd": NUMBER,
    "title": STRING, "summary": STRING, "coverage": STRING,
    "events": {"type": "array", "items": EVENT, "maxItems": 100},
    "predictions": {"type": "array", "items": PREDICTION, "maxItems": 200},
})
REPORT_SCHEMA["properties"]["analysis"] = {"type": "array", "items": FINDING, "maxItems": 200}

# Models do not judge their own retrieval coverage. The host appends this
# optional wire field after checking the per-run retrieval ledger.
MODEL_REPORT_SCHEMA = copy.deepcopy(REPORT_SCHEMA)
MODEL_REPORT_SCHEMA["required"].append("analysis")
MODEL_REPORT_SCHEMA["properties"]["predictions"]["items"]["required"].append("findingIds")
REPORT_SCHEMA["properties"]["coverageComplete"] = {"type": "boolean"}
# Optional for archived reports; never requested from model output. The host
# records the exact selected model after generation and consistency review.
REPORT_SCHEMA["properties"]["model"] = {"type": "string", "minLength": 1, "maxLength": 200}
