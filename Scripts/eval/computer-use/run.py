#!/usr/bin/env python3
"""Live native acceptance over the shipping stdio MCP server; no mock fallback.

The model gets computer tools and pixels only. Private fixture state is used by
the independent grader, never by the agent. --mode smoke deliberately uses that
state to diagnose I/O and is reported separately from model capability.
"""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).with_name("Fixture.swift")
GOAL = ("Use only the computer tool to complete the order form on screen. Read the displayed "
        "order code, enter it in the text field, tick Confirm order, and click Save order exactly "
        "once. Then take a screenshot to read the newly generated receipt. Reply with only that "
        "receipt, with no other words. Do not guess the receipt or use keyboard shortcuts.")


class Blocked(RuntimeError):
    pass


class Child:
    """Bounded, newline-delimited protocol; owns only the child it launches."""
    def __init__(self, command, log, env=None):
        self.log = open(log, "wb")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, env=env)
        self.buffer = b""

    def send(self, value):
        if not isinstance(value, str):
            value = json.dumps(value)
        self.process.stdin.write(value.encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        if time.monotonic() >= deadline:
            raise TimeoutError("Child protocol deadline exceeded")
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], max(0, remaining))[0]:
                raise TimeoutError("Child protocol deadline exceeded")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Child exited before sending a response; see stderr artifact")
            self.buffer += chunk
            if len(self.buffer) > 32 * 1024 * 1024:
                raise RuntimeError("Child protocol response exceeded 32 MiB")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        if not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        self.process.stdout.close()
        self.log.close()


class MCP(Child):
    sequence = 0

    def request(self, method, params, deadline):
        if time.monotonic() >= deadline:
            raise TimeoutError("MCP deadline exceeded before dispatch")
        self.sequence += 1
        request_id = self.sequence
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            response = self.receive(deadline)
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError("MCP protocol error: " + json.dumps(response["error"]))
                return response["result"]

    def initialize(self, deadline):
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                     "clientInfo": {"name": "mca-live-acceptance", "version": "1"}}, deadline)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def jpeg_dimensions(data):
    """Read encoded image dimensions; never parse a human-readable tool summary."""
    if not data.startswith(b"\xff\xd8"):
        raise ValueError("Screenshot is not a JPEG")
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            break
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        length = int.from_bytes(data[offset:offset + 2], "big")
        if length < 2 or offset + length > len(data):
            break
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} and length >= 7:
            height = int.from_bytes(data[offset + 3:offset + 5], "big")
            width = int.from_bytes(data[offset + 5:offset + 7], "big")
            if width > 0 and height > 0:
                return width, height
            break
        offset += length
    raise ValueError("Screenshot has no valid JPEG dimensions")


def grade(state, answer, trace, mode):
    """The success claim and the API's 'clicked' string are never the oracle."""
    saves = [i for i, event in enumerate(trace) if event.get("saves_after", 0) > 0]
    reobserved = bool(saves) and any(event["action"] == "screenshot" and event.get("image")
                                   for event in trace[saves[0] + 1:])
    checks = {
        "saved_exact_order": state.get("saved_text") == state.get("order") and bool(state.get("order")),
        "exactly_one_save": state.get("saves") == 1 and state.get("attempts") == 1,
        "confirmed_by_input": state.get("confirmed") is True and state.get("confirmation_clicks", 0) >= 1,
        "real_text_input": state.get("edits", 0) > 0,
        "receipt_created": bool(re.fullmatch(r"R-[0-9A-F]{12}", state.get("receipt", ""))),
        "post_save_screenshot": reobserved,
        "receipt_reported": mode == "smoke" or answer.strip() == state.get("receipt", "") != "",
    }
    return {"passed": all(checks.values()), "checks": checks}


def validate_action(args, width, height):
    # The benchmark is confined to its opaque native fixture, with no shell,
    # browser, filesystem tools, global shortcuts, or held input states.
    if args.get("action") not in {"screenshot", "left_click", "type", "wait"}:
        raise ValueError("This native benchmark allows screenshot, left_click, type and wait only")
    action = args["action"]
    allowed = {"action"} | {"left_click": {"coordinate"}, "type": {"text"}, "wait": {"duration"}}.get(action, set())
    if set(args) - allowed:
        raise ValueError("Unexpected action parameters")
    if action == "left_click":
        point = args.get("coordinate")
        if (not isinstance(point, list) or len(point) != 2 or
                any(type(n) not in (int, float) or not math.isfinite(n) for n in point) or
                not (20 <= point[0] < width - 20 and 20 <= point[1] < height - 20)):
            raise ValueError("Click must be inside the fixture image")
    if action == "type" and (not isinstance(args.get("text"), str) or
                              not re.fullmatch(r"[A-Za-z0-9 -]{1,80}", args["text"])):
        raise ValueError("Only short order-code text is allowed")
    if action == "wait" and (type(args.get("duration")) not in (int, float) or
                              not 0 <= args["duration"] <= 2):
        raise ValueError("Wait must be between zero and two seconds")


def gemini_turn(model, key, contents, schema, deadline):
    body = {"systemInstruction": {"parts": [{"text": "Operate the visible native test application. "
             "Use screenshots to determine positions and verify results. " + GOAL}]},
            "contents": contents, "tools": [{"functionDeclarations": [
                {"name": "computer", "description": "The shipping MCA MCP computer tool.", "parameters": schema}]}],
            "generationConfig": {"maxOutputTokens": 4096, "temperature": 0}}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "x-goog-api-key": key})
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Trial deadline exceeded")
    try:
        with urllib.request.urlopen(request, timeout=min(45, remaining)) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        # Provider error bodies can echo credentials or request data. Keep them out of reports.
        raise Blocked(f"Gemini API returned HTTP {error.code}") from None
    candidates = result.get("candidates", [])
    if not candidates or not candidates[0].get("content", {}).get("parts"):
        raise RuntimeError("Model returned no usable content")
    return candidates[0]["content"], result.get("usageMetadata", {})


def trial(args, fixture_binary, folder):
    folder.mkdir()
    deadline = time.monotonic() + args.timeout
    native = server = None
    trace, state, answer = [], {}, ""
    result = {"mode": args.mode, "status": "failed", "trace": trace}
    child_env = dict(os.environ)
    child_env.pop("GEMINI_API_KEY", None)
    try:
        native = Child([str(fixture_binary)], folder / "fixture.stderr", child_env)
        initial = native.receive(deadline)
        state = initial
        result["initial"] = initial
        if not initial.get("frontmost"):
            raise Blocked("Native fixture could not acquire foreground; no capture or input was attempted")
        # TCC is attributed per responsible process/code identity. The fixture
        # does not synthesize input: its trust flag cannot preflight the server.
        # Exercise the actual MCP path and classify its permission error instead.

        def observe():
            native.send("status")
            observed = native.receive(deadline)
            if observed.get("run_id") != initial["run_id"] or not observed.get("frontmost") or not observed.get("visible"):
                raise RuntimeError("Fixture lost foreground/identity; refusing further capture or input")
            return observed

        # No user configuration, context DB, or browser session is modified.
        config = folder / "config.json"
        config.write_text(json.dumps({"databaseURL": (folder / "context.sqlite3").resolve().as_uri(),
                                      "mcpAllowDangerousTools": False, "browser": {"enabled": False}}))
        server = MCP([str(args.mca), "mcp", "--computer-use", "--config", str(config.resolve())],
                     folder / "mcp.stderr", child_env)
        server.initialize(deadline)
        definitions = server.request("tools/list", {}, deadline)["tools"]
        published = next(tool["inputSchema"] for tool in definitions if tool["name"] == "computer")
        schema = {"type": "object", "required": ["action"], "properties": {
            name: value for name, value in published["properties"].items()
            if name in {"action", "coordinate", "text", "duration"}}}
        schema["properties"]["action"] = {"type": "string", "enum": ["screenshot", "left_click", "type", "wait"]}
        (folder / "tool-schema.json").write_text(json.dumps(schema, indent=2) + "\n")
        width = height = 0

        def computer(arguments):
            nonlocal width, height, state
            observe()
            validate_action(arguments, width, height)
            event = {"action": arguments["action"], "arguments": arguments,
                     "elapsed_seconds": round(args.timeout - (deadline - time.monotonic()), 3)}
            trace.append(event)
            response = server.request("tools/call", {"name": "computer", "arguments": arguments}, deadline)
            state = observe()
            event["saves_after"] = state["saves"]
            content = response.get("content", [])
            if response.get("isError"):
                reason = " ".join(item.get("text", "") for item in content if item.get("type") == "text")
                if re.search(r"permission|not granted|not trusted", reason, re.IGNORECASE):
                    raise Blocked("Production computer tool permission failure: " + reason)
                raise RuntimeError("Production computer tool failed: " + reason)
            parts = []
            texts = []
            for item in content:
                if item["type"] == "image":
                    data = base64.b64decode(item["data"], validate=True)
                    if arguments["action"] == "screenshot":
                        width, height = jpeg_dimensions(data)
                    image_name = f"screen-{len(trace):02}.jpg"
                    (folder / image_name).write_bytes(data)
                    event["image"] = image_name
                    parts.append({"inlineData": {"mimeType": item["mimeType"], "data": item["data"]}})
                elif item["type"] == "text":
                    texts.append(item["text"])
            text = "\n".join(texts)
            event["result"] = text
            if arguments["action"] == "screenshot":
                if not parts or not width or not height:
                    raise RuntimeError("Production screenshot is missing image/dimensions")
            return text, parts

        text, images = computer({"action": "screenshot"})
        if args.mode == "no-input":
            # Deliberately fails the same grader. It must never turn green just
            # because MCP connected or a screenshot was returned.
            computer({"action": "screenshot"})
        elif args.mode == "smoke":
            # Diagnostic baseline only: privileged positions/code never go to the model.
            def point(name):
                x, y = initial[name]
                scale = width / initial["width"]
                return [round(x * scale), round(y * scale)]
            computer({"action": "left_click", "coordinate": point("field")})
            computer({"action": "type", "text": initial["order"]})
            computer({"action": "left_click", "coordinate": point("confirm")})
            computer({"action": "left_click", "coordinate": point("save")})
            computer({"action": "screenshot"})
        else:
            contents = [{"role": "user", "parts": [{"text": GOAL + "\n" + text}] + images}]
            for _ in range(args.max_turns):
                content, usage = gemini_turn(args.model, os.environ["GEMINI_API_KEY"], contents, schema, deadline)
                # Preserve thought signatures exactly when replaying Gemini tool calls.
                contents.append(content)
                result.setdefault("usage", []).append(usage)
                calls = [p["functionCall"] for p in content["parts"] if "functionCall" in p]
                if not calls:
                    answer = "".join(p.get("text", "") for p in content["parts"] if not p.get("thought"))
                    break
                if len(trace) + len(calls) > args.max_actions:
                    raise RuntimeError("Action budget exhausted")
                results = []
                for call in calls:
                    if call.get("name") != "computer":
                        raise RuntimeError("Model requested an unexposed tool")
                    text, images = computer(call.get("args", {}))
                    response_part = {"functionResponse": {"name": "computer", "response": {"result": text}}}
                    if call.get("id"):
                        response_part["functionResponse"]["id"] = call["id"]
                    results.append(response_part)
                    results.extend(images)
                contents.append({"role": "user", "parts": results})
            else:
                raise RuntimeError("Model turn budget exhausted")
        state = observe()
        result.update(grade(state, answer, trace, args.mode))
        result["status"] = "passed" if result["passed"] else "failed"
    except Blocked as error:
        result.update(status="blocked", error=str(error))
    except KeyboardInterrupt:
        result.update(status="interrupted", error="Interrupted by the operator")
    except (OSError, ValueError, RuntimeError, TimeoutError, KeyError, StopIteration) as error:
        result.update(status="failed", error=str(error))
    finally:
        result.update(final=state, answer=answer,
                      duration_seconds=round(args.timeout - (deadline - time.monotonic()), 3))
        if server:
            server.close()
        if native:
            native.close()
        (folder / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["smoke", "agent", "no-input"], default="agent")
    parser.add_argument("--live", action="store_true", help="Allow a temporary opaque main-display window and real input")
    parser.add_argument("--mca", type=Path, default=ROOT / ".build/debug/mca")
    parser.add_argument("--model", help="Explicit Gemini model ID; required in agent mode")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory (never overwritten)")
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=150)
    parser.add_argument("--max-turns", type=int, default=16)
    parser.add_argument("--max-actions", type=int, default=24)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.mca = args.mca.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"version": 1, "run_id": str(uuid.uuid4()), "mode": args.mode,
              "scope": "native-order-form-v1; MCP client path, not Copilot/browser acceptance",
              "model": args.model if args.mode == "agent" else None,
              "requested_trials": args.trials, "status": "blocked", "trials": []}
    exit_code = 2
    try:
        if not args.live:
            raise Blocked("Live execution requires --live; no desktop action was performed")
        if sys.platform != "darwin":
            raise Blocked("A logged-in macOS desktop is required")
        if not 1 <= args.trials <= 20 or not 10 <= args.timeout <= 180:
            raise Blocked("Use 1–20 trials and a 10–180 second trial timeout")
        if not 1 <= args.max_turns <= 40 or not 1 <= args.max_actions <= 80:
            raise Blocked("Use 1–40 model turns and 1–80 actions")
        if args.mode == "agent" and (not args.model or not re.fullmatch(r"[A-Za-z0-9._-]+", args.model)):
            raise Blocked("Agent mode requires an explicit --model Gemini model ID")
        if args.mode == "agent" and not os.environ.get("GEMINI_API_KEY"):
            raise Blocked("GEMINI_API_KEY is missing; use secret run GEMINI_API_KEY -- ...")
        if not args.mca.is_file():
            raise Blocked("Build the production mca executable first: swift build")
        report["provenance"] = {"mca_sha256": sha(args.mca), "fixture_sha256": sha(FIXTURE),
                                "runner_sha256": sha(__file__),
                                "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                                "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))}
        with tempfile.TemporaryDirectory(prefix="mca-native-eval-") as temporary:
            binary = Path(temporary) / "fixture"
            with open(args.output / "build.log", "wb") as log:
                subprocess.run(["swiftc", "-swift-version", "6", str(FIXTURE), "-o", str(binary)],
                               check=True, stdout=log, stderr=log, timeout=120)
            report["provenance"]["fixture_binary_sha256"] = sha(binary)
            for index in range(args.trials):
                result = trial(args, binary, args.output / f"trial-{index + 1:02}")
                report["trials"].append({"trial": index + 1, "status": result["status"],
                                         "checks": result.get("checks", {}), "error": result.get("error")})
                print(f"{args.mode} trial {index + 1}/{args.trials}: {result['status']}", flush=True)
                if result["status"] in {"blocked", "interrupted"}:
                    break
        passed = sum(t["status"] == "passed" for t in report["trials"])
        report["passed_trials"] = passed
        report["success_rate"] = passed / args.trials
        report["status"] = ("interrupted" if any(t["status"] == "interrupted" for t in report["trials"]) else
                            "passed" if passed == args.trials else
                            "blocked" if any(t["status"] == "blocked" for t in report["trials"]) else "failed")
        exit_code = {"passed": 0, "failed": 1, "blocked": 2, "interrupted": 130}[report["status"]]
    except (Blocked, OSError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{report['status']}: {args.output / 'report.json'}", flush=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
