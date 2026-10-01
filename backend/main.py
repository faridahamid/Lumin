import base64
import hashlib
import json
import os
import uuid
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from prompt_loader import PromptLoader


def load_dotenv() -> None:
    env_path = Path(".env")
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip().lstrip("\ufeff")
        value = value.strip().strip("\"'")
        if key:
            os.environ[key] = value


load_dotenv()

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_REALTIME_MODEL = os.getenv("OPENAI_REALTIME_MODEL", "gpt-realtime")
OPENAI_TEXT_MODEL = os.getenv("OPENAI_TEXT_MODEL", "gpt-4.1-mini")
OPENAI_WEB_SEARCH_MODEL = os.getenv("OPENAI_WEB_SEARCH_MODEL", OPENAI_TEXT_MODEL)
OPENAI_TRANSCRIBE_MODEL = os.getenv("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")
OPENAI_REALTIME_VOICE = os.getenv("OPENAI_REALTIME_VOICE", "verse")
OPENAI_TTS_MODEL = os.getenv("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
OPENAI_TTS_VOICE = os.getenv("OPENAI_TTS_VOICE", "alloy")
GOOGLE_CLOUD_VISION_API_KEY = os.getenv("GOOGLE_CLOUD_VISION_API_KEY")
EDGE_TTS_VOICE = os.getenv("EDGE_TTS_VOICE", "ar-EG-SalmaNeural")
EDGE_TTS_RATE = os.getenv("EDGE_TTS_RATE", "+0%")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("OPENAI_TIMEOUT_SECONDS", "90"))
MIDAS_MODEL_PATH = os.getenv("MIDAS_MODEL_PATH", "models/midas_v2_1_small.tflite")
MIDAS_INPUT_SIZE = int(os.getenv("MIDAS_INPUT_SIZE", "256"))
READ_TEXT_NO_TEXT_AR = "مش لاقي نص واضح دلوقتي. ثبّت الكاميرا وهحاول تاني."
PROMPTS = PromptLoader(Path(__file__).resolve().parent / "prompts")

SYSTEM_INSTRUCTIONS = PROMPTS.render(
    "system/main_agent.md",
    user_question="Live voice conversation",
    scene_context="Current camera context will be provided during the conversation.",
    language="Egyptian Arabic",
)

FALLBACK_ANSWER = "مش شايف حاجة واضحة قدامي دلوقتي."

app = FastAPI(title="Lumin Backend", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

_midas_interpreter: Any | None = None


class AskRequest(BaseModel):
    question: str = Field(..., min_length=1)
    objects: list[str] = Field(default_factory=list)
    imageBase64: str | None = None
    imageMimeType: str = "image/jpeg"


class AskResponse(BaseModel):
    answer: str


class AskVoiceResponse(BaseModel):
    answer: str
    audioBase64: str
    audioMimeType: str


class TtsRequest(BaseModel):
    text: str = Field(..., min_length=1)


class TtsResponse(BaseModel):
    audioBase64: str
    audioMimeType: str
    voice: str


class TranscribeRequest(BaseModel):
    audioBase64: str = Field(..., min_length=1)
    audioMimeType: str = "audio/wav"
    language: str = "ar"


class TranscribeResponse(BaseModel):
    text: str


class HomeRouteRequest(BaseModel):
    command: str = Field(..., min_length=1)


class HomeRouteResponse(BaseModel):
    tool: str
    destination: str | None = None
    clarification: str | None = None


class ReadTextRequest(BaseModel):
    imageBase64: str = Field(..., min_length=1)
    imageMimeType: str = "image/jpeg"


class ReadTextResponse(BaseModel):
    answer: str
    summary: str
    fullText: str
    rawOcr: dict[str, Any]


class ReadTextQuestionRequest(BaseModel):
    question: str = Field(..., min_length=1)
    fullText: str = Field(..., min_length=1)
    rawOcr: dict[str, Any] | None = None


class ReadTextQuestionResponse(BaseModel):
    answer: str
    routeTool: str | None = None
    searchQuery: str | None = None


class WebCitation(BaseModel):
    title: str
    url: str


class WebSearchRequest(BaseModel):
    question: str = Field(..., min_length=1)
    history: list[dict[str, str]] = Field(default_factory=list)


class WebSearchResponse(BaseModel):
    answer: str
    citations: list[WebCitation] = Field(default_factory=list)


class DepthBox(BaseModel):
    left: float
    top: float
    right: float
    bottom: float


class MidasDepthRequest(BaseModel):
    imageBase64: str = Field(..., min_length=1)
    imageMimeType: str = "image/jpeg"
    boxes: list[DepthBox] = Field(default_factory=list)


class MidasDepthResponse(BaseModel):
    scores: list[int]
    proximities: list[str]


HOME_ROUTER_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "name": "open_object_detection",
        "description": (
            "Open the live object detection camera screen when the user wants "
            "to know what is around them, identify objects, or use the camera."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Brief reason for choosing this route.",
                }
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "open_ocr",
        "description": (
            "Open the text reading/OCR screen when the user wants to read "
            "printed text, labels, documents, signs, screens, or pages."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Brief reason for choosing this route.",
                }
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "open_web_search",
        "description": (
            "Open the web search screen when the user asks for current facts, "
            "news, online information, or anything that requires the internet."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Brief reason for choosing this route.",
                }
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "clarify",
        "description": (
            "Use only when the command is too unclear to choose object "
            "detection, OCR, or web search."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": (
                        "Short spoken clarification question in the user's "
                        "language when possible."
                    ),
                }
            },
            "required": ["question"],
            "additionalProperties": False,
        },
    },
]


OCR_CONTEXT_ROUTER_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "name": "answer_from_context",
        "description": (
            "Answer using only the extracted OCR text when the text contains "
            "enough information for the user's question."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Why the OCR text is enough to answer.",
                }
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "web_search",
        "description": (
            "Use the existing web-search flow when the OCR text does not "
            "contain enough information or the user asks for current/outside "
            "information related to the captured text."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Search query combining the user's question with the "
                        "relevant OCR context."
                    ),
                },
                "reason": {
                    "type": "string",
                    "description": "Why web search is needed.",
                },
            },
            "required": ["query", "reason"],
            "additionalProperties": False,
        },
    },
]


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "ok": True,
        "provider": "openai",
        "textModel": OPENAI_TEXT_MODEL,
        "webSearchModel": OPENAI_WEB_SEARCH_MODEL,
        "transcribeModel": OPENAI_TRANSCRIBE_MODEL,
        "realtimeModel": OPENAI_REALTIME_MODEL,
        "keyFingerprint": key_fingerprint(OPENAI_API_KEY),
        "visionKeyFingerprint": key_fingerprint(GOOGLE_CLOUD_VISION_API_KEY),
    }


@app.get("/debug/auth")
async def debug_auth() -> dict[str, Any]:
    require_api_key()

    payload = {
        "model": "gpt-4.1-mini",
        "input": "Reply with ok.",
        "max_output_tokens": 16,
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        try:
            data = response.json()
            message = data.get("error", {}).get("message") or response.text
        except Exception:
            message = response.text or response.reason_phrase
        return {
            "ok": False,
            "status": response.status_code,
            "message": message,
            "keyFingerprint": key_fingerprint(OPENAI_API_KEY),
        }

    return {
        "ok": True,
        "status": response.status_code,
        "keyFingerprint": key_fingerprint(OPENAI_API_KEY),
    }


@app.post("/ask", response_model=AskResponse)
async def ask(request: AskRequest) -> AskResponse:
    require_api_key()

    question = request.question.strip()
    objects = [str(item).strip() for item in request.objects if str(item).strip()]
    image_base64 = (request.imageBase64 or "").strip()
    image_mime_type = request.imageMimeType or "image/jpeg"

    if not question:
        raise HTTPException(status_code=400, detail="question is required")

    if not objects:
        return AskResponse(answer=FALLBACK_ANSWER)

    prompt = build_scene_prompt(question, objects)

    try:
        answer = await ask_openai(prompt, image_base64, image_mime_type)
    except Exception:
        if not image_base64:
            raise
        answer = await ask_openai(prompt, "", image_mime_type)

    return AskResponse(answer=answer or FALLBACK_ANSWER)


@app.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(request: TranscribeRequest) -> TranscribeResponse:
    require_api_key()

    audio_base64 = request.audioBase64.strip()
    if not audio_base64:
        raise HTTPException(status_code=400, detail="audioBase64 is required")

    try:
        audio = base64.b64decode(audio_base64, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="audioBase64 is invalid") from exc

    try:
        text = await transcribe_openai(
            audio=audio,
            audio_mime_type=request.audioMimeType or "audio/wav",
            language=request.language.strip(),
        )
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="OpenAI transcription timed out. Try again.",
        ) from exc

    return TranscribeResponse(text=text.strip())


@app.post("/route-home-command", response_model=HomeRouteResponse)
async def route_home_command(request: HomeRouteRequest) -> HomeRouteResponse:
    require_api_key()

    command = request.command.strip()
    if not command:
        raise HTTPException(status_code=400, detail="command is required")

    try:
        tool_name, arguments = await choose_home_route_tool(command)
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="OpenAI routing timed out. Try again.",
        ) from exc

    print(f"Home router tool={tool_name} args={json.dumps(arguments, ensure_ascii=False)}")
    destinations = {
        "open_object_detection": "object_detection",
        "open_ocr": "ocr",
        "open_web_search": "web_search",
    }
    if tool_name in destinations:
        return HomeRouteResponse(
            tool=tool_name,
            destination=destinations[tool_name],
        )

    clarification = str(arguments.get("question") or "").strip()
    return HomeRouteResponse(
        tool="clarify",
        clarification=clarification or "تحب أفتح الكاميرا، قراءة النص، ولا البحث؟",
    )


@app.post("/ask-voice", response_model=AskVoiceResponse)
async def ask_voice(request: AskRequest) -> AskVoiceResponse:
    require_api_key()

    question = request.question.strip()
    objects = [str(item).strip() for item in request.objects if str(item).strip()]
    image_base64 = (request.imageBase64 or "").strip()
    image_mime_type = request.imageMimeType or "image/jpeg"

    if not question:
        raise HTTPException(status_code=400, detail="question is required")

    if not objects:
        answer = FALLBACK_ANSWER
        try:
            audio = await text_to_speech(answer)
        except httpx.TimeoutException as exc:
            raise HTTPException(
                status_code=504,
                detail="OpenAI text-to-speech timed out. Try again.",
            ) from exc
        return AskVoiceResponse(
            answer=answer,
            audioBase64=base64.b64encode(audio).decode("ascii"),
            audioMimeType="audio/mpeg",
        )

    prompt = build_scene_prompt(question, objects)
    try:
        answer = await ask_openai(prompt, image_base64, image_mime_type)
    except Exception:
        if not image_base64:
            raise
        answer = await ask_openai(prompt, "", image_mime_type)

    answer = answer or FALLBACK_ANSWER
    try:
        audio = await text_to_speech(answer)
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="OpenAI text-to-speech timed out. Try again.",
        ) from exc
    return AskVoiceResponse(
        answer=answer,
        audioBase64=base64.b64encode(audio).decode("ascii"),
        audioMimeType="audio/mpeg",
    )


@app.post("/read-text", response_model=ReadTextResponse)
async def read_text(request: ReadTextRequest) -> ReadTextResponse:
    require_api_key()
    require_vision_api_key()

    image_base64 = normalize_base64_image(
        request.imageBase64,
        request.imageMimeType or "image/jpeg",
    )
    raw_ocr = await extract_text_with_google_vision(image_base64)
    full_text = extract_vision_full_text(raw_ocr)
    if not full_text:
        answer = READ_TEXT_NO_TEXT_AR
        return ReadTextResponse(
            answer=answer,
            summary=answer,
            fullText="",
            rawOcr=raw_ocr,
        )

    answer = await analyze_ocr_text(full_text, raw_ocr)
    summary = extract_first_sentence(answer) or "Text captured."
    return ReadTextResponse(
        answer=answer,
        summary=summary,
        fullText=full_text,
        rawOcr=raw_ocr,
    )


@app.post("/read-text/question", response_model=ReadTextQuestionResponse)
async def read_text_question(
    request: ReadTextQuestionRequest,
) -> ReadTextQuestionResponse:
    require_api_key()

    question = request.question.strip()
    full_text = request.fullText.strip()
    if not question:
        raise HTTPException(status_code=400, detail="question is required")
    if not full_text:
        raise HTTPException(status_code=400, detail="fullText is required")

    answer, route_tool, search_query = await answer_ocr_question_with_contextual_fallback(
        question=question,
        full_text=full_text,
        raw_ocr=request.rawOcr or {},
    )
    return ReadTextQuestionResponse(
        answer=answer,
        routeTool=route_tool,
        searchQuery=search_query,
    )


@app.post("/web-search", response_model=WebSearchResponse)
async def web_search(request: WebSearchRequest) -> WebSearchResponse:
    require_api_key()

    question = request.question.strip()
    if not question:
        raise HTTPException(status_code=400, detail="question is required")

    try:
        answer, citations = await answer_with_web_search(question, request.history)
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="OpenAI web search timed out. Try again.",
        ) from exc

    return WebSearchResponse(answer=answer, citations=citations)


@app.post("/depth/midas", response_model=MidasDepthResponse)
async def depth_midas(request: MidasDepthRequest) -> MidasDepthResponse:
    image_base64 = normalize_base64_image(
        request.imageBase64,
        request.imageMimeType or "image/jpeg",
    )
    try:
        image_bytes = base64.b64decode(image_base64, validate=True)
        scores = estimate_midas_scores(image_bytes, request.boxes)
    except FileNotFoundError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Missing MiDaS model at {MIDAS_MODEL_PATH}",
        ) from exc
    except ImportError as exc:
        raise HTTPException(
            status_code=500,
            detail=(
                "Missing MiDaS dependencies. Install numpy, pillow, and "
                "ai-edge-litert."
            ),
        ) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"MiDaS depth failed: {exc}") from exc

    return MidasDepthResponse(
        scores=scores,
        proximities=[midas_proximity_label(score) for score in scores],
    )


@app.post("/tts-edge", response_model=TtsResponse)
async def tts_edge(request: TtsRequest) -> TtsResponse:
    text = request.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    try:
        audio = await edge_text_to_speech(text)
    except ImportError as exc:
        raise HTTPException(
            status_code=500,
            detail="Missing edge-tts. Run: pip install -r requirements.txt",
        ) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Edge TTS failed: {exc}",
        ) from exc

    return TtsResponse(
        audioBase64=base64.b64encode(audio).decode("ascii"),
        audioMimeType="audio/mpeg",
        voice=EDGE_TTS_VOICE,
    )


@app.post("/tts-openai", response_model=TtsResponse)
async def tts_openai(request: TtsRequest) -> TtsResponse:
    require_api_key()

    text = request.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    try:
        audio = await text_to_speech(text)
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="OpenAI text-to-speech timed out. Try again.",
        ) from exc

    return TtsResponse(
        audioBase64=base64.b64encode(audio).decode("ascii"),
        audioMimeType="audio/mpeg",
        voice=OPENAI_TTS_VOICE,
    )


@app.post("/realtime/client-secret")
async def create_realtime_client_secret() -> dict[str, Any]:
    require_api_key()

    payload = {
        "session": {
            "type": "realtime",
            "model": OPENAI_REALTIME_MODEL,
            "instructions": SYSTEM_INSTRUCTIONS,
            "audio": {"output": {"voice": OPENAI_REALTIME_VOICE}},
        }
    }

    timeout = httpx.Timeout(
        REQUEST_TIMEOUT_SECONDS,
        connect=20.0,
        read=REQUEST_TIMEOUT_SECONDS,
        write=20.0,
        pool=20.0,
    )
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            "https://api.openai.com/v1/realtime/client_secrets",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        print_openai_error("Realtime client secret", response)
        raise openai_http_error(response)

    return response.json()


@app.post("/realtime/session")
async def create_realtime_session(request: Request) -> Response:
    require_api_key()

    sdp = normalize_sdp((await request.body()).decode("utf-8", errors="replace"))
    print(f"Realtime SDP offer length: {len(sdp)}")
    if not sdp:
        raise HTTPException(status_code=400, detail="SDP offer is required")

    session_config = {
        "type": "realtime",
        "model": OPENAI_REALTIME_MODEL,
        "instructions": SYSTEM_INSTRUCTIONS,
        "audio": {"output": {"voice": OPENAI_REALTIME_VOICE}},
    }

    body, content_type = build_multipart_form(
        {
            "sdp": sdp,
            "session": json.dumps(session_config),
        }
    )
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/realtime/calls",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": content_type,
            },
            content=body,
        )

    if response.status_code >= 400:
        print_openai_error("Realtime session", response)
        raise openai_http_error(response)

    return Response(content=response.text, media_type="application/sdp")


def require_api_key() -> None:
    if not OPENAI_API_KEY:
        raise HTTPException(
            status_code=500,
            detail="Missing OPENAI_API_KEY. Add it to lumin-backend/.env.",
        )


def require_vision_api_key() -> None:
    if not GOOGLE_CLOUD_VISION_API_KEY:
        raise HTTPException(
            status_code=500,
            detail=(
                "Missing GOOGLE_CLOUD_VISION_API_KEY. Add it to "
                "lumin-backend/.env."
            ),
        )


def key_fingerprint(api_key: str | None) -> str:
    if not api_key:
        return "missing"

    digest = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    suffix = api_key[-4:] if len(api_key) >= 4 else "short"
    return f"sha256:{digest[:10]}...{suffix}"


def build_multipart_form(fields: dict[str, str]) -> tuple[bytes, str]:
    boundary = f"lumin-{uuid.uuid4().hex}"
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(
                "utf-8"
            )
        )
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def normalize_sdp(sdp: str) -> str:
    normalized = sdp.strip().replace("\r\n", "\n").replace("\n", "\r\n")
    return f"{normalized}\r\n" if normalized else ""


def build_scene_prompt(question: str, objects: list[str]) -> str:
    scene = ", ".join(objects[:20]) if objects else "No objects detected"
    return PROMPTS.render(
        "system/main_agent.md",
        user_question=question,
        scene_context=scene,
        language="Egyptian Arabic",
    )


async def ask_openai(
    prompt: str,
    image_base64: str,
    image_mime_type: str,
) -> str:
    content: list[dict[str, Any]] = [{"type": "input_text", "text": prompt}]
    if image_base64:
        content.append(
            {
                "type": "input_image",
                "image_url": build_data_url(image_base64, image_mime_type),
            }
        )

    payload = {
        "model": OPENAI_TEXT_MODEL,
        "input": [{"role": "user", "content": content}],
        "max_output_tokens": 80,
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        raise openai_http_error(response)

    data = response.json()
    return extract_response_text(data).strip()


async def extract_text_with_google_vision(image_base64: str) -> dict[str, Any]:
    payload = {
        "requests": [
            {
                "image": {"content": image_base64},
                "features": [{"type": "DOCUMENT_TEXT_DETECTION"}],
                "imageContext": {
                    "languageHints": [
                        "ar",
                        "en",
                        "fr",
                        "de",
                        "es",
                        "it",
                        "pt",
                        "tr",
                    ]
                },
            }
        ]
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://vision.googleapis.com/v1/images:annotate",
            params={"key": GOOGLE_CLOUD_VISION_API_KEY},
            json=payload,
        )

    if response.status_code >= 400:
        try:
            message = response.json().get("error", {}).get("message") or response.text
        except Exception:
            message = response.text or response.reason_phrase
        raise HTTPException(
            status_code=502,
            detail=f"Google Vision {response.status_code}: {message}",
        )

    data = response.json()
    responses = data.get("responses")
    first = responses[0] if isinstance(responses, list) and responses else {}
    if isinstance(first, dict) and first.get("error"):
        message = first.get("error", {}).get("message") or "Vision OCR failed"
        raise HTTPException(status_code=502, detail=f"Google Vision: {message}")
    return first if isinstance(first, dict) else {}


async def analyze_ocr_text(full_text: str, raw_ocr: dict[str, Any]) -> str:
    language_rule = reading_language_rule(full_text)
    prompt = PROMPTS.render(
        "tools/ocr.md",
        language_rule=language_rule,
        full_text=full_text,
        ocr_context=json.dumps(compact_vision_json(raw_ocr), ensure_ascii=False),
    )
    return await ask_text_only_openai(prompt, max_output_tokens=900)


async def choose_home_route_tool(command: str) -> tuple[str, dict[str, Any]]:
    prompt = PROMPTS.render(
        "tools/home_router.md",
        user_command=command,
    )
    return await ask_openai_function_tool(
        prompt=prompt,
        tools=HOME_ROUTER_TOOLS,
        fallback_tool="clarify",
        max_output_tokens=80,
    )


async def answer_ocr_question_with_contextual_fallback(
    question: str,
    full_text: str,
    raw_ocr: dict[str, Any],
) -> tuple[str, str, str | None]:
    language_rule = question_language_rule(question, full_text)
    route_prompt = PROMPTS.render(
        "tools/ocr_context_router.md",
        user_question=question,
        language_rule=language_rule,
        full_text=full_text[:8000],
        ocr_context=json.dumps(compact_vision_json(raw_ocr), ensure_ascii=False),
    )
    tool_name, arguments = await ask_openai_function_tool(
        prompt=route_prompt,
        tools=OCR_CONTEXT_ROUTER_TOOLS,
        fallback_tool="answer_from_context",
        max_output_tokens=120,
    )

    print(f"OCR context router tool={tool_name} args={json.dumps(arguments, ensure_ascii=False)}")
    if tool_name != "web_search":
        answer = await answer_text_question(
            question=question,
            full_text=full_text,
            raw_ocr=raw_ocr,
        )
        return answer, "answer_from_context", None

    query = str(arguments.get("query") or "").strip()
    if not query:
        query = f"{question}\n\nOCR context:\n{full_text[:1200]}"
    print(f"OCR context router running web_search query={query}")
    search_answer, citations = await answer_with_web_search(query, [])
    final_prompt = PROMPTS.render(
        "tools/ocr_web_final.md",
        user_question=question,
        language_rule=language_rule,
        full_text=full_text[:8000],
        search_answer=search_answer,
        citations=json.dumps(
            [citation.model_dump() for citation in citations],
            ensure_ascii=False,
        ),
    )
    answer = await ask_text_only_openai(final_prompt, max_output_tokens=360)
    return answer, "web_search", query


async def answer_text_question(
    question: str,
    full_text: str,
    raw_ocr: dict[str, Any],
) -> str:
    language_rule = question_language_rule(question, full_text)
    prompt = PROMPTS.render(
        "tools/ocr_question.md",
        user_question=question,
        language_rule=language_rule,
        full_text=full_text,
        ocr_context=json.dumps(compact_vision_json(raw_ocr), ensure_ascii=False),
    )
    return await ask_text_only_openai(prompt, max_output_tokens=260)


async def answer_with_web_search(
    question: str,
    history: list[dict[str, str]],
) -> tuple[str, list[WebCitation]]:
    conversation_context = compact_web_history(history)
    prompt = PROMPTS.render(
        "tools/web_search.md",
        user_question=question,
        conversation_context=conversation_context,
    )
    payload = {
        "model": OPENAI_WEB_SEARCH_MODEL,
        "tools": [{"type": "web_search"}],
        "tool_choice": "required",
        "input": [{"role": "user", "content": [{"type": "input_text", "text": prompt}]}],
        "max_output_tokens": 700,
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        raise openai_http_error(response)

    data = response.json()
    search_answer = extract_response_text(data).strip()
    citations = extract_url_citations(data)
    clean_answer = await summarize_web_search_for_speech(
        question=question,
        search_answer=search_answer,
        citations=citations,
        history=conversation_context,
    )
    return clean_answer, citations


async def summarize_web_search_for_speech(
    question: str,
    search_answer: str,
    citations: list[WebCitation],
    history: str,
) -> str:
    prompt = PROMPTS.render(
        "tools/web_search_summarize.md",
        user_question=question,
        conversation_context=history,
        search_answer=search_answer,
        citations=json.dumps(
            [citation.model_dump() for citation in citations],
            ensure_ascii=False,
        ),
    )
    answer = await ask_text_only_openai(prompt, max_output_tokens=360)
    return strip_spoken_source_noise(answer) or strip_spoken_source_noise(search_answer)


async def ask_openai_function_tool(
    prompt: str,
    tools: list[dict[str, Any]],
    fallback_tool: str,
    max_output_tokens: int,
) -> tuple[str, dict[str, Any]]:
    payload = {
        "model": OPENAI_TEXT_MODEL,
        "tools": tools,
        "tool_choice": "required",
        "input": [{"role": "user", "content": [{"type": "input_text", "text": prompt}]}],
        "max_output_tokens": max_output_tokens,
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        raise openai_http_error(response)

    return extract_function_tool_call(response.json(), fallback_tool)


async def ask_text_only_openai(prompt: str, max_output_tokens: int) -> str:
    payload = {
        "model": OPENAI_TEXT_MODEL,
        "input": [{"role": "user", "content": [{"type": "input_text", "text": prompt}]}],
        "max_output_tokens": max_output_tokens,
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        raise openai_http_error(response)

    return extract_response_text(response.json()).strip()


async def text_to_speech(text: str) -> bytes:
    payload = {
        "model": OPENAI_TTS_MODEL,
        "voice": OPENAI_TTS_VOICE,
        "input": text,
        "format": "mp3",
    }

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/speech",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        print_openai_error("Text to speech", response)
        raise openai_http_error(response)

    return response.content


async def transcribe_openai(
    audio: bytes,
    audio_mime_type: str,
    language: str,
) -> str:
    filename = "speech.wav" if "wav" in audio_mime_type else "speech.audio"
    data = {
        "model": OPENAI_TRANSCRIBE_MODEL,
        "response_format": "json",
    }
    if language:
        data["language"] = language

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
            data=data,
            files={"file": (filename, audio, audio_mime_type)},
        )

    if response.status_code >= 400:
        print_openai_error("Transcription", response)
        raise openai_http_error(response)

    payload = response.json()
    text = payload.get("text")
    return text if isinstance(text, str) else ""


async def edge_text_to_speech(text: str) -> bytes:
    import edge_tts

    communicate = edge_tts.Communicate(
        text=text,
        voice=EDGE_TTS_VOICE,
        rate=EDGE_TTS_RATE,
    )
    chunks: list[bytes] = []
    async for chunk in communicate.stream():
        if chunk.get("type") == "audio":
            data = chunk.get("data")
            if isinstance(data, bytes):
                chunks.append(data)

    audio = b"".join(chunks)
    if not audio:
        raise RuntimeError("No audio returned")
    return audio


def estimate_midas_scores(image_bytes: bytes, boxes: list[DepthBox]) -> list[int]:
    from PIL import Image
    import numpy as np
    import io

    interpreter = load_midas_interpreter()
    input_size = MIDAS_INPUT_SIZE
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    original_width, original_height = image.size
    try:
        resampling = Image.Resampling.BILINEAR
    except AttributeError:
        resampling = Image.BILINEAR
    resized = image.resize((input_size, input_size), resampling)

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    input_dtype = input_details[0]["dtype"]

    if input_dtype == np.uint8:
        input_tensor = np.asarray(resized, dtype=np.uint8)
    else:
        input_tensor = np.asarray(resized, dtype=np.float32) / 127.5 - 1.0
    input_tensor = np.expand_dims(input_tensor, axis=0)

    interpreter.set_tensor(input_details[0]["index"], input_tensor)
    interpreter.invoke()

    depth = interpreter.get_tensor(output_details[0]["index"]).squeeze().astype(np.float32)
    depth = 1.0 / (depth + 1e-6)

    if depth.shape != (original_height, original_width):
        depth_image = Image.fromarray(depth)
        depth = np.asarray(
            depth_image.resize((original_width, original_height), resampling),
            dtype=np.float32,
        )

    min_depth = float(np.min(depth))
    max_depth = float(np.max(depth))
    if not np.isfinite(min_depth) or not np.isfinite(max_depth) or max_depth <= min_depth:
        return [255 for _ in boxes]

    normalized = np.rint(((depth - min_depth) / (max_depth - min_depth)) * 255)
    normalized = np.clip(normalized, 0, 255).astype(np.uint8)
    return [
        median_depth_score(
            normalized=normalized,
            width=original_width,
            height=original_height,
            box=box,
        )
        for box in boxes
    ]


def load_midas_interpreter() -> Any:
    global _midas_interpreter
    if _midas_interpreter is not None:
        return _midas_interpreter

    model_path = Path(MIDAS_MODEL_PATH)
    if not model_path.is_absolute():
        model_path = Path(__file__).resolve().parent / model_path
    if not model_path.exists():
        raise FileNotFoundError(str(model_path))

    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            import tensorflow as tf

            Interpreter = tf.lite.Interpreter

    interpreter = Interpreter(
        model_path=str(model_path),
        num_threads=int(os.getenv("MIDAS_THREADS", "4")),
    )
    interpreter.allocate_tensors()
    _midas_interpreter = interpreter
    return interpreter


def median_depth_score(
    normalized: Any,
    width: int,
    height: int,
    box: DepthBox,
) -> int:
    import numpy as np

    center_x = round(((box.left + box.right) * 0.5) * width)
    center_y = round(((box.top + box.bottom) * 0.5) * height)
    patch_half_width = max(1, round(((box.right - box.left) * width) * 0.1))
    patch_half_height = max(1, round(((box.bottom - box.top) * height) * 0.1))

    x1 = int(max(0, min(width - 1, center_x - patch_half_width)))
    x2 = int(max(0, min(width, center_x + patch_half_width)))
    y1 = int(max(0, min(height - 1, center_y - patch_half_height)))
    y2 = int(max(0, min(height, center_y + patch_half_height)))

    if x2 <= x1 or y2 <= y1:
        return 255

    patch = normalized.reshape((height, width))[y1:y2, x1:x2]
    if patch.size == 0:
        return 255
    return int(np.median(patch))


def midas_proximity_label(score: int) -> str:
    if score <= 35:
        return "VERY CLOSE"
    if score <= 60:
        return "CLOSE"
    if score <= 100:
        return "MID"
    return "FAR"


def build_data_url(image_base64: str, image_mime_type: str) -> str:
    if image_base64.startswith("data:"):
        return image_base64

    try:
        base64.b64decode(image_base64, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="imageBase64 is invalid") from exc

    return f"data:{image_mime_type};base64,{image_base64}"


def normalize_base64_image(image_base64: str, image_mime_type: str) -> str:
    value = image_base64.strip()
    if value.startswith("data:"):
        _, _, value = value.partition(",")

    try:
        base64.b64decode(value, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="imageBase64 is invalid") from exc

    return value


def extract_vision_full_text(raw_ocr: dict[str, Any]) -> str:
    full_text = raw_ocr.get("fullTextAnnotation", {}).get("text")
    if isinstance(full_text, str) and full_text.strip():
        return full_text.strip()

    annotations = raw_ocr.get("textAnnotations")
    if isinstance(annotations, list) and annotations:
        first = annotations[0]
        if isinstance(first, dict):
            description = first.get("description")
            if isinstance(description, str):
                return description.strip()

    return ""


def compact_vision_json(raw_ocr: dict[str, Any]) -> dict[str, Any]:
    text_annotations = raw_ocr.get("textAnnotations")
    words: list[dict[str, Any]] = []
    if isinstance(text_annotations, list):
        for item in text_annotations[1:80]:
            if not isinstance(item, dict):
                continue
            description = item.get("description")
            if not isinstance(description, str) or not description.strip():
                continue
            words.append(
                {
                    "text": description,
                    "locale": item.get("locale"),
                    "boundingPoly": item.get("boundingPoly"),
                }
            )

    return {
        "fullText": extract_vision_full_text(raw_ocr)[:6000],
        "words": words,
    }


def reading_language_rule(text: str) -> str:
    language = detect_text_language(text)
    if language == "arabic":
        return (
            "The OCR text is mostly Arabic. Reply in Arabic, and read Arabic "
            "content in Arabic. Keep English names, numbers, and brand text as-is."
        )
    if language == "english":
        return (
            "The OCR text is mostly English. Use Arabic for assistant comments, "
            "but read the captured English text in English. Keep names and numbers as-is."
        )
    if language == "french":
        return (
            "The OCR text is mostly French. Use Arabic for assistant comments, "
            "but read the captured French text in French. Keep names and numbers as-is."
        )
    if language == "latin":
        return (
            "The OCR text is in a Latin-script language. Use Arabic for assistant "
            "comments, but read the captured text in its original language. Do not "
            "assume it is English."
        )
    return (
        "The OCR text is mixed or in a non-English Latin-script language. Use Arabic "
        "for assistant comments, but keep every captured text segment in its original "
        "language, including French, English, or any other language."
    )


def question_language_rule(question: str, text: str) -> str:
    question_language = detect_text_language(question)
    text_language = detect_text_language(text)
    if question_language == "arabic":
        return "The user asked in Arabic. Answer in Arabic unless quoting English text."
    if question_language == "english":
        return "The user asked in English. Answer in English unless quoting Arabic text."
    if question_language == "french":
        return "The user asked in French. Answer in French unless quoting Arabic text."
    if question_language == "latin":
        return (
            "The user asked in a Latin-script language. Answer in that language when "
            "clear; otherwise use Arabic. Keep quoted captured text in its original language."
        )
    return reading_language_rule(text) if text_language != "mixed" else (
        "Answer in the clearest language for the user's question. Keep quoted "
        "captured text in its original language."
    )


def detect_text_language(text: str) -> str:
    arabic = 0
    latin = 0
    lower_words = f" {text.lower()} "
    for char in text:
        code = ord(char)
        if 0x0600 <= code <= 0x06FF or 0x0750 <= code <= 0x077F or 0x08A0 <= code <= 0x08FF:
            arabic += 1
        elif ("A" <= char <= "Z") or ("a" <= char <= "z"):
            latin += 1

    total = arabic + latin
    if total == 0:
        return "mixed"
    if arabic / total >= 0.55:
        return "arabic"
    if latin / total >= 0.55 and looks_french(lower_words):
        return "french"
    if latin / total >= 0.55 and looks_english(lower_words):
        return "english"
    if latin / total >= 0.55:
        return "latin"
    return "mixed"


def looks_french(lower_text: str) -> bool:
    if any(char in lower_text for char in "àâçéèêëîïôùûüÿœæ"):
        return True
    markers = [
        " le ",
        " la ",
        " les ",
        " des ",
        " une ",
        " est ",
        " avec ",
        " pour ",
        " dans ",
        " chapitre ",
        " monsieur ",
        " madame ",
    ]
    return sum(1 for marker in markers if marker in lower_text) >= 3


def looks_english(lower_text: str) -> bool:
    markers = [
        " the ",
        " and ",
        " of ",
        " to ",
        " in ",
        " is ",
        " with ",
        " for ",
        " chapter ",
        " page ",
    ]
    return sum(1 for marker in markers if marker in lower_text) >= 2


def extract_first_sentence(text: str) -> str:
    cleaned = " ".join(text.strip().split())
    if not cleaned:
        return ""
    for marker in [". ", "؟ ", "? ", "! ", "۔ "]:
        index = cleaned.find(marker)
        if index > 0:
            return cleaned[: index + 1]
    return cleaned[:180]


def extract_response_text(data: dict[str, Any]) -> str:
    output_text = data.get("output_text")
    if isinstance(output_text, str):
        return output_text

    chunks: list[str] = []
    for output in data.get("output", []):
        if not isinstance(output, dict):
            continue
        for content in output.get("content", []):
            if not isinstance(content, dict):
                continue
            text = content.get("text")
            if isinstance(text, str):
                chunks.append(text)

    return "".join(chunks)


def extract_function_tool_call(
    data: dict[str, Any],
    fallback_tool: str,
) -> tuple[str, dict[str, Any]]:
    for output in data.get("output", []):
        if not isinstance(output, dict):
            continue
        if output.get("type") == "function_call":
            name = str(output.get("name") or "").strip()
            arguments = parse_tool_arguments(output.get("arguments"))
            if name:
                return name, arguments
        for content in output.get("content", []):
            if not isinstance(content, dict):
                continue
            if content.get("type") == "function_call":
                name = str(content.get("name") or "").strip()
                arguments = parse_tool_arguments(content.get("arguments"))
                if name:
                    return name, arguments

    return fallback_tool, {}


def parse_tool_arguments(raw_arguments: Any) -> dict[str, Any]:
    if isinstance(raw_arguments, dict):
        return raw_arguments
    if isinstance(raw_arguments, str) and raw_arguments.strip():
        try:
            parsed = json.loads(raw_arguments)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def compact_web_history(history: list[dict[str, str]]) -> str:
    lines: list[str] = []
    for item in history[-8:]:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        content = " ".join(str(item.get("content") or "").split())
        if role not in {"user", "assistant"} or not content:
            continue
        label = "User" if role == "user" else "Lumin"
        lines.append(f"{label}: {content[:900]}")
    return "\n".join(lines) if lines else "No previous web search conversation."


def strip_spoken_source_noise(text: str) -> str:
    cleaned_lines: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        lower = line.lower()
        if line.startswith(("http://", "https://", "- http://", "- https://")):
            continue
        if lower.startswith(("sources:", "source:", "citations:", "citation:", "references:")):
            continue
        cleaned_lines.append(line)

    cleaned = " ".join(cleaned_lines).strip()
    while "[" in cleaned and "]" in cleaned:
        start = cleaned.find("[")
        end = cleaned.find("]", start)
        if start == -1 or end == -1 or end - start > 12:
            break
        token = cleaned[start + 1 : end].strip()
        if token.isdigit() or token.lower().startswith("source"):
            cleaned = (cleaned[:start] + cleaned[end + 1 :]).strip()
        else:
            break
    return " ".join(cleaned.split())


def extract_url_citations(data: dict[str, Any]) -> list[WebCitation]:
    citations: list[WebCitation] = []
    seen_urls: set[str] = set()

    for output in data.get("output", []):
        if not isinstance(output, dict):
            continue
        for content in output.get("content", []):
            if not isinstance(content, dict):
                continue
            for annotation in content.get("annotations", []):
                if not isinstance(annotation, dict):
                    continue
                if annotation.get("type") != "url_citation":
                    continue
                url = str(annotation.get("url") or "").strip()
                if not url or url in seen_urls:
                    continue
                title = str(annotation.get("title") or "").strip() or url
                citations.append(WebCitation(title=title, url=url))
                seen_urls.add(url)

    return citations


def openai_http_error(response: httpx.Response) -> HTTPException:
    try:
        data = response.json()
        message = data.get("error", {}).get("message") or response.text
    except Exception:
        message = response.text or response.reason_phrase
    return HTTPException(status_code=502, detail=f"OpenAI {response.status_code}: {message}")


def print_openai_error(context: str, response: httpx.Response) -> None:
    try:
        data = response.json()
        message = data.get("error", {}).get("message") or response.text
    except Exception:
        message = response.text or response.reason_phrase
    print(f"{context} OpenAI error {response.status_code}: {message}")
