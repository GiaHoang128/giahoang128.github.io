#!/usr/bin/env python3
import argparse
import json
import random
import re
import sys
import time
from typing import Any, Dict, Iterable, Optional, Tuple, Set

import requests


TEMP_MAIL_BASE = "https://web2.temp-mail.org"
ORIGIN = "https://temp-mail.org"
REFERER = "https://temp-mail.org/"
DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

OTP_REGEX = re.compile(r"\b(\d{5,6})\b")


def _deep_find_first_key(data: Any, candidate_keys: Iterable[str]) -> Optional[Any]:
    """Depth-first search for the first matching key among candidates."""
    if isinstance(data, dict):
        for key in candidate_keys:
            if key in data:
                return data[key]
        for value in data.values():
            found = _deep_find_first_key(value, candidate_keys)
            if found is not None:
                return found
    elif isinstance(data, list):
        for item in data:
            found = _deep_find_first_key(item, candidate_keys)
            if found is not None:
                return found
    return None


def _build_proxies(proxy_spec: Optional[str]) -> Optional[Dict[str, str]]:
    """Build requests proxies dict from a simple spec.

    Accepts either a full URL (http://user:pass@host:port) or compact forms:
    - host:port
    - host:port:user:pass
    """
    if not proxy_spec:
        return None

    spec = proxy_spec.strip()
    if "://" in spec:
        proxy_url = spec
    else:
        parts = spec.split(":")
        if len(parts) not in (2, 4):
            raise ValueError(
                "proxy spec must be 'host:port' or 'host:port:user:pass' or full URL"
            )
        host, port = parts[0], parts[1]
        if len(parts) == 4:
            user, pwd = parts[2], parts[3]
            auth = f"{user}:{pwd}@"
        else:
            auth = ""
        proxy_url = f"http://{auth}{host}:{port}"

    return {"http": proxy_url, "https": proxy_url}


def _new_session(proxy_spec: Optional[str] = None) -> requests.Session:
    s = requests.Session()
    s.headers.update(
        {
            "User-Agent": DEFAULT_UA,
        }
    )
    proxies = _build_proxies(proxy_spec)
    if proxies:
        s.proxies.update(proxies)
    return s


def _apply_common_headers(headers: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    base = {
        "Origin": ORIGIN,
        "Referer": REFERER,
        "User-Agent": DEFAULT_UA,
    }
    if headers:
        base.update(headers)
    return base


def create_mailbox(session: Optional[requests.Session] = None) -> Tuple[str, str]:
    """Create a new temp-mail mailbox and return (email, token)."""
    must_close = False
    if session is None:
        session = _new_session()
        must_close = True

    try:
        url = f"{TEMP_MAIL_BASE}/mailbox"
        resp = session.post(url, headers=_apply_common_headers(), timeout=30)
        resp.raise_for_status()
        data = resp.json()

        # Try to find email and token robustly
        email = _deep_find_first_key(data, ("email", "address", "mailbox"))
        token = _deep_find_first_key(data, ("token", "auth_token", "mailbox_token"))
        if not email or not token:
            raise RuntimeError(
                f"Unexpected mailbox response; could not find email/token: {json.dumps(data)[:500]}"
            )
        return str(email), str(token)
    finally:
        if must_close:
            session.close()


def _auth_headers(token: str) -> Dict[str, str]:
    return _apply_common_headers({"Authorization": f"Bearer {token}"})


def list_messages(token: str, session: Optional[requests.Session] = None) -> Any:
    must_close = False
    if session is None:
        session = _new_session()
        must_close = True
    try:
        url = f"{TEMP_MAIL_BASE}/messages"
        resp = session.get(url, headers=_auth_headers(token), timeout=30)
        resp.raise_for_status()
        try:
            return resp.json()
        except json.JSONDecodeError:
            # Fallback: return raw text
            return resp.text
    finally:
        if must_close:
            session.close()


def get_message(token: str, message_id: str, session: Optional[requests.Session] = None) -> Any:
    must_close = False
    if session is None:
        session = _new_session()
        must_close = True
    try:
        url = f"{TEMP_MAIL_BASE}/messages/{message_id}"
        resp = session.get(url, headers=_auth_headers(token), timeout=30)
        resp.raise_for_status()
        try:
            return resp.json()
        except json.JSONDecodeError:
            return resp.text
    finally:
        if must_close:
            session.close()


def _extract_text_blobs(obj: Any) -> Iterable[str]:
    """Yield text content from a potentially nested JSON structure."""
    stack = [obj]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            for v in current.values():
                stack.append(v)
        elif isinstance(current, list):
            for it in current:
                stack.append(it)
        else:
            if current is None:
                continue
            if isinstance(current, (str, bytes)):
                try:
                    yield current.decode("utf-8") if isinstance(current, bytes) else current
                except Exception:
                    continue
            else:
                # Coerce common primitives
                yield str(current)


def extract_otp_from_content(obj: Any) -> Optional[str]:
    """Search for a 5-6 digit OTP code within any text fields."""
    for text in _extract_text_blobs(obj):
        m = OTP_REGEX.search(text)
        if m:
            return m.group(1)
    return None


def poll_for_otp(
    token: str,
    session: Optional[requests.Session] = None,
    timeout_seconds: int = 120,
    interval_seconds: float = 3.0,
) -> Optional[str]:
    """Poll messages until an OTP is found or timeout expires.

    Returns the OTP string on success, or None if not found.
    """
    must_close = False
    if session is None:
        session = _new_session()
        must_close = True

    deadline = time.time() + timeout_seconds
    seen_ids: Set[str] = set()

    try:
        while time.time() < deadline:
            try:
                messages = list_messages(token, session=session)
            except Exception:
                messages = []

            # Messages may be a list or an object
            candidates: Iterable[Any]
            if isinstance(messages, list):
                candidates = messages
            elif isinstance(messages, dict):
                # Try common container keys
                candidates = messages.get("messages") or messages.get("data") or []
                if not isinstance(candidates, list):
                    candidates = []
            else:
                candidates = []

            # Try to find OTP from subjects quickly
            found_in_list = extract_otp_from_content(candidates)
            if found_in_list:
                return found_in_list

            # Otherwise, fetch each message body for OTP
            # Visit newest first if order key exists; else as is
            for msg in candidates:
                msg_id = None
                if isinstance(msg, dict):
                    msg_id = (
                        msg.get("id")
                        or msg.get("_id")
                        or msg.get("message_id")
                        or msg.get("uid")
                    )
                if not msg_id or str(msg_id) in seen_ids:
                    continue

                try:
                    detail = get_message(token, str(msg_id), session=session)
                except Exception:
                    seen_ids.add(str(msg_id))
                    continue

                found = extract_otp_from_content(detail)
                if found:
                    return found

                seen_ids.add(str(msg_id))

            time.sleep(interval_seconds)

        return None
    finally:
        if must_close:
            session.close()


def _choose_random_proxy(proxy_list: Optional[str]) -> Optional[str]:
    if not proxy_list:
        return None
    # proxy_list is a comma-separated string of proxy specs
    items = [p.strip() for p in proxy_list.split(",") if p.strip()]
    if not items:
        return None
    return random.choice(items)


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Temp-mail.org Python client")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_create = sub.add_parser("create", help="Create a new mailbox")
    p_create.add_argument(
        "--proxy",
        help="Proxy spec: full URL or host:port or host:port:user:pass",
        default=None,
    )
    p_create.add_argument(
        "--proxies",
        help="Comma-separated list of proxy specs to choose randomly",
        default=None,
    )

    p_list = sub.add_parser("list", help="List messages")
    p_list.add_argument("--token", required=True)
    p_list.add_argument("--proxy", default=None)
    p_list.add_argument("--proxies", default=None)

    p_get = sub.add_parser("get", help="Get a message by ID")
    p_get.add_argument("--token", required=True)
    p_get.add_argument("--id", required=True)
    p_get.add_argument("--proxy", default=None)
    p_get.add_argument("--proxies", default=None)

    p_poll = sub.add_parser("poll", help="Poll for OTP in messages")
    p_poll.add_argument("--token", required=True)
    p_poll.add_argument("--timeout", type=int, default=120)
    p_poll.add_argument("--interval", type=float, default=3.0)
    p_poll.add_argument("--proxy", default=None)
    p_poll.add_argument("--proxies", default=None)

    args = parser.parse_args(list(argv) if argv is not None else None)

    # Determine proxy choice
    proxy_spec = args.proxy or _choose_random_proxy(getattr(args, "proxies", None))

    try:
        if args.cmd == "create":
            with _new_session(proxy_spec) as s:
                email, token = create_mailbox(s)
                print(f"{email}|{token}")
            return 0

        if args.cmd == "list":
            with _new_session(proxy_spec) as s:
                lst = list_messages(args.token, session=s)
                if isinstance(lst, (dict, list)):
                    print(json.dumps(lst, ensure_ascii=False, indent=2))
                else:
                    print(str(lst))
            return 0

        if args.cmd == "get":
            with _new_session(proxy_spec) as s:
                msg = get_message(args.token, args.id, session=s)
                if isinstance(msg, (dict, list)):
                    print(json.dumps(msg, ensure_ascii=False, indent=2))
                else:
                    print(str(msg))
            return 0

        if args.cmd == "poll":
            with _new_session(proxy_spec) as s:
                code = poll_for_otp(
                    token=args.token,
                    session=s,
                    timeout_seconds=args.timeout,
                    interval_seconds=args.interval,
                )
                if code:
                    print(code)
                    return 0
                print("", end="")
                return 2  # not found

        print("Unknown command", file=sys.stderr)
        return 1
    except requests.HTTPError as http_err:
        print(f"HTTP error: {http_err}", file=sys.stderr)
        if http_err.response is not None:
            try:
                print(http_err.response.text[:1000], file=sys.stderr)
            except Exception:
                pass
        return 1
    except Exception as ex:
        print(f"Error: {ex}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
