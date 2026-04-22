#!/usr/bin/env python3
"""Walk two pffexport output trees, merge + dedupe by Message-ID, upload to Mailcow via IMAP.

Design choices (locked in):
- Mailbox-name encoding: IMAP4rev1 modified-UTF-7 (RFC 3501 §5.1.3) so German umlauts work
  regardless of whether the server advertises UTF8=ACCEPT.
- Dedupe: prefer source 2 (newer OST) on Message-ID collision; messages without a
  Message-ID are all kept (accepted dup risk).
- Folder mapping: "Posteingang" -> INBOX; its children become top-level folders.
  Well-known German/English mail folders mapped to conventional IMAP names
  (Sent / Drafts / Trash / Junk / Archive). Custom folders kept verbatim.
- INTERNALDATE: preserved per message via Date header (fallback to OutlookHeaders).
- Flags: all messages uploaded with \\Seen (state restore, not new delivery).
"""
import argparse
import base64
import datetime
import hashlib
import imaplib
import re
import ssl
import sys
from email.message import EmailMessage
from email.parser import Parser
from email.policy import default as epol
from email.utils import formatdate, parsedate_to_datetime
from pathlib import Path


# Base64-encoded multi-MB attachments can produce IMAP literals much larger than
# imaplib's default 1 MB. Raise to 10 MB. (IMAP APPEND uses literals so the
# server-side imap_max_line_length does NOT apply; this is just Python's safety.)
imaplib._MAXLINE = 10_000_000

IMAP_HOST = "127.0.0.1"
IMAP_PORT = 143
USER = "info@fraefel.de"
PASSWORD = None  # filled via --password
RECONNECT_EVERY = 50  # proactive session refresh to dodge dovecot idle timeouts
SKIP_PATH_PREFIXES = (
    "Stamm", "IPM_SUBTREE", "NON_IPM", "Allgemeine", "Suche", "Verknüpfungen", "Ansichten",
    "Erinnerungen", "Aufgabensuche", "Nachverfolgte", "Drizzle", "ItemProcSearch",
    "SPAM Search Folder", "Freigegebene Daten", "~MAPISP", "_MAPISP",
    "EFORMS REGISTRY", "Organisatorische Formulare", "Conversation Action Settings",
    "Junk-E-Mail", "Kontakte", "Files", "Yammer-Stamm", "ExternalContacts",
    "Notizen", "Verlauf der Unterhaltung", "Einstellungen", "Social Activity",
    "Freebusy", "Subscriptions", "Contact Search", "IPM_VIEWS", "IPM_COMMON_VIEWS",
    "MS-OLK-", "Aufgaben", "Kalender", "RSS-Feeds",
)
FOLDER_MAP = {
    "posteingang": "INBOX", "inbox": "INBOX",
    "gesendete elemente": "Sent", "gesendete objekte": "Sent", "sent items": "Sent", "sent": "Sent",
    "entwürfe": "Drafts", "drafts": "Drafts",
    "gelöschte elemente": "Trash", "gelöschte objekte": "Trash", "deleted items": "Trash",
    "trash": "Trash", "papierkorb": "Trash",
    "junk": "Junk",
    "archiv": "Archive", "archive": "Archive",
    "synchronisierungsprobleme": "Sync-Errors",
    "synchronisierungsprobleme (nur dieser computer)": "Sync-Errors",
    "postausgang": "Outbox",
}


def log(msg):
    print(msg, flush=True)


def imap_mb_encode(s):
    """Modified-UTF-7 encoding for IMAP mailbox names (RFC 3501 §5.1.3)."""
    out, buf = [], []
    def flush():
        if buf:
            raw = "".join(buf).encode("utf-16-be")
            b64 = base64.b64encode(raw).decode("ascii").rstrip("=").replace("/", ",")
            out.append("&" + b64 + "-")
            buf.clear()
    for c in s:
        o = ord(c)
        if 0x20 <= o <= 0x7E:
            flush()
            if c == "&":
                out.append("&-")
            else:
                out.append(c)
        else:
            buf.append(c)
    flush()
    return "".join(out)


def sanitize_component(c):
    return c.replace("\\", "").replace("/", "_").strip()


def map_folder(parts):
    p = [x for x in parts if not any(x.startswith(pfx) for pfx in SKIP_PATH_PREFIXES)]
    if not p:
        return "INBOX"
    first = p[0].lower()
    if first in FOLDER_MAP:
        p[0] = FOLDER_MAP[first]
    if p[0] == "INBOX" and len(p) > 1:
        p = p[1:]
    elif p[0] == "INBOX":
        return "INBOX"
    clean = [sanitize_component(x) for x in p if x and x.strip()]
    return "/".join(x for x in clean if x) or "INBOX"


def walk_msgdirs(root):
    for d in root.rglob("Message[0-9]*"):
        if not d.is_dir() or not re.fullmatch(r"Message\d+", d.name):
            continue
        rel = d.relative_to(root)
        # Skip nested messages inside Attachments
        if any(p == "Attachments" for p in rel.parts):
            continue
        yield d, list(rel.parts[:-1])


def parse_outlook_headers(path):
    out = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return out
    for line in text.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            k = k.strip()
            v = v.strip()
            if k and k not in out:
                out[k] = v
    return out


def get_message_id(msg_dir):
    ih = msg_dir / "InternetHeaders.txt"
    if not ih.exists():
        return None
    try:
        text = ih.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return None
    m = re.search(r"^Message-ID:\s*(.+?)$", text, re.MULTILINE | re.IGNORECASE)
    if not m:
        return None
    v = m.group(1).strip().strip("<>").strip()
    return v if v and "@" in v else None


def get_internaldate(msg_dir):
    ih = msg_dir / "InternetHeaders.txt"
    if ih.exists():
        try:
            text = ih.read_text(encoding="utf-8", errors="replace")
            m = re.search(r"^Date:\s*(.+?)$", text, re.MULTILINE)
            if m:
                dt = parsedate_to_datetime(m.group(1).strip())
                if dt:
                    return dt
        except Exception:
            pass
    oh = msg_dir / "OutlookHeaders.txt"
    if oh.exists():
        h = parse_outlook_headers(oh)
        for key in ("Delivery time", "Client submit time", "Creation time"):
            if key in h:
                s = re.sub(r"\.\d+", "", h[key])
                for fmt in ("%b %d, %Y %H:%M:%S %Z", "%b %d, %Y %H:%M:%S"):
                    try:
                        dt = datetime.datetime.strptime(s, fmt)
                        return dt.replace(tzinfo=datetime.timezone.utc)
                    except Exception:
                        pass
    return datetime.datetime.now(tz=datetime.timezone.utc)


def get_body(msg_dir):
    for ext, subtype in (("html", "html"), ("txt", "plain"), ("rtf", "plain")):
        p = msg_dir / f"Message.{ext}"
        if p.exists():
            try:
                data = p.read_bytes()
                text = data.decode("utf-8", errors="replace")
                if ext == "rtf":
                    text = re.sub(r"\\[a-z]+\d* ?", "", text)
                    text = re.sub(r"[{}]", "", text)
                    text = text.replace("\\\\", "\\").replace("\\'", "'")
                    return text, "plain"
                return text, subtype
            except Exception:
                pass
    return "(body not recoverable)", "plain"


def get_attachments(msg_dir):
    adir = msg_dir / "Attachments"
    if not adir.is_dir():
        return []
    out = []
    for entry in sorted(adir.iterdir()):
        if entry.is_file():
            name = re.sub(r"^\d+_", "", entry.name)
            try:
                out.append((name, entry.read_bytes()))
            except Exception:
                pass
        elif entry.is_dir():
            for sub in sorted(entry.iterdir()):
                if sub.is_file() and sub.name != "OutlookHeaders.txt":
                    name = re.sub(r"^\d+_", "", sub.name)
                    try:
                        out.append((name, sub.read_bytes()))
                    except Exception:
                        pass
                    break
    return out


def build_rfc822(msg_dir):
    ih = msg_dir / "InternetHeaders.txt"
    oh = msg_dir / "OutlookHeaders.txt"
    msg = EmailMessage(policy=epol)
    skip_h = {"content-type", "content-transfer-encoding", "content-disposition", "mime-version"}

    if ih.exists():
        try:
            text = ih.read_text(encoding="utf-8", errors="replace")
            hdrs = Parser(policy=epol).parsestr(text, headersonly=True)
            for k, v in hdrs.items():
                if k.lower() in skip_h:
                    continue
                try:
                    msg[k] = v
                except Exception:
                    pass
        except Exception:
            pass

    if "From" not in msg and oh.exists():
        h = parse_outlook_headers(oh)
        name = h.get("Sender name", "")
        addr = h.get("Sender email address", "")
        if "@" in addr:
            msg["From"] = f'"{name}" <{addr}>' if name and name != addr else addr
        elif "@" in name:
            msg["From"] = name
        else:
            msg["From"] = '"(unknown)" <unknown@restored.fraefel.local>'

    if "Subject" not in msg and oh.exists():
        h = parse_outlook_headers(oh)
        msg["Subject"] = h.get("Subject") or h.get("Conversation topic") or "(no subject)"

    if "To" not in msg and "Cc" not in msg:
        msg["To"] = "info@fraefel.de"

    if "Date" not in msg:
        dt = get_internaldate(msg_dir)
        msg["Date"] = formatdate(dt.timestamp(), usegmt=True)

    if "Message-ID" not in msg:
        key = f"{msg.get('From','')}|{msg.get('Subject','')}|{msg.get('Date','')}"
        h = hashlib.sha256(key.encode("utf-8", errors="replace")).hexdigest()[:24]
        msg["Message-ID"] = f"<restored-{h}@fraefel.restored>"

    body_text, body_sub = get_body(msg_dir)
    if body_sub == "html":
        msg.set_content(body_text, subtype="html")
    else:
        msg.set_content(body_text or "(empty)")

    for name, data in get_attachments(msg_dir):
        try:
            msg.add_attachment(data, maintype="application", subtype="octet-stream", filename=name)
        except Exception as e:
            log(f"  [warn] attach failed for '{name}' in {msg_dir.name}: {e}")

    try:
        return bytes(msg)
    except Exception as e:
        log(f"  [warn] serialize failed for {msg_dir}: {e}")
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src1", required=True)
    ap.add_argument("--src2", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src1 = Path(args.src1)
    src2 = Path(args.src2)

    # Phase A: collect
    log("=== phase A: collect ===")
    collected = []
    for label, root in (("F2", src2), ("F1", src1)):
        c = 0
        for msg_dir, parts in walk_msgdirs(root):
            folder = map_folder(parts)
            mid = get_message_id(msg_dir)
            dt = get_internaldate(msg_dir)
            collected.append((label, msg_dir, folder, mid, dt))
            c += 1
        log(f"  {label}: {c} messages from {root}")
    log(f"  total: {len(collected)}")

    # Phase B: dedupe
    log("=== phase B: dedupe (F2 wins on Message-ID collision) ===")
    seen, dedup, dups = set(), [], 0
    for e in collected:
        _, _, _, mid, _ = e
        if mid:
            if mid in seen:
                dups += 1
                continue
            seen.add(mid)
        dedup.append(e)
    log(f"  dropped {dups} Message-ID duplicates. remaining {len(dedup)}.")

    # Phase C: connect + enable UTF-8
    log(f"=== phase C: connect to {IMAP_HOST}:{IMAP_PORT} ===")

    def _connect():
        imap = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        imap.starttls(ssl_context=ctx)
        imap.login(USER, args.password)
        try:
            imap._simple_command("ENABLE", "UTF8=ACCEPT")
        except Exception:
            pass
        return imap

    imap = _connect()
    log("  authenticated")

    # Phase C2: resume-safe pre-scan — fetch existing Message-IDs per folder
    log("=== phase C2: pre-scan existing Message-IDs (resume-safe) ===")
    target_folders = sorted({("INBOX" if f == "INBOX" else f) for (_, _, f, _, _) in dedup} | {"INBOX"})
    existing_ids_by_folder = {}
    total_existing = 0
    for folder in target_folders:
        try:
            enc = imap_mb_encode(folder)
            typ, _ = imap._simple_command("SELECT", '"' + enc + '"')
            if typ != "OK":
                existing_ids_by_folder[folder] = set()
                continue
            # Transition imaplib internal state to SELECTED so FETCH is legal
            imap.state = "SELECTED"
            typ, data = imap._simple_command("FETCH", "1:*", "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
            typ2, resp = imap.response("FETCH")
            ids = set()
            for entry in (resp or []):
                if isinstance(entry, tuple) and len(entry) >= 2:
                    payload = entry[1] if isinstance(entry[1], bytes) else entry[1].encode("utf-8", "replace")
                    text = payload.decode("utf-8", errors="replace")
                    m = re.search(r"Message-ID:\s*<?([^>\r\n]+)>?", text, re.IGNORECASE)
                    if m:
                        ids.add(m.group(1).strip())
            existing_ids_by_folder[folder] = ids
            total_existing += len(ids)
            try: imap._simple_command("CLOSE")
            except Exception: pass
        except Exception as e:
            log(f"  [warn] pre-scan {folder!r}: {e}")
            existing_ids_by_folder[folder] = set()
    log(f"  pre-scan complete: {total_existing} existing messages indexed across {len(target_folders)} folders")

    # Phase D: folder pre-create
    log("=== phase D: folder pre-create (modified-UTF-7) ===")
    folders = sorted({f for (_, _, f, _, _) in dedup if f and f != "INBOX"})
    log(f"  creating {len(folders)} folders")
    failed = set()
    for mb in folders:
        enc = imap_mb_encode(mb)
        typ, data = imap._simple_command("CREATE", '"' + enc + '"')
        if typ != "OK":
            resp = (data[0] or b"").decode("utf-8", errors="replace")
            if "already exists" in resp.lower():
                continue
            log(f"  [warn] create {mb!r}: {resp}")
            failed.add(mb)
    log(f"  created {len(folders) - len(failed)} / failed {len(failed)}")

    # Phase E: upload with reconnect-on-failure + periodic refresh
    log("=== phase E: upload ===")
    if args.dry_run:
        log("  dry-run: skipping upload")
        try: imap.logout()
        except Exception: pass
        return 0

    def _append_with_retry(imap_ref, mb_enc, flags, internaldate, eml):
        """Returns (imap, typ, data_or_err). On reconnect, replaces imap.
        Quote the mailbox name so spaces + UTF-7 chars don't break IMAP parsing."""
        mb_quoted = '"' + mb_enc + '"'
        try:
            typ, data = imap_ref.append(mb_quoted, flags, internaldate, eml)
            return imap_ref, typ, data
        except (imaplib.IMAP4.abort, imaplib.IMAP4.error, ssl.SSLError, OSError) as e:
            log(f"    [reconnect] append raised {type(e).__name__}: {str(e)[:120]}")
            try: imap_ref.logout()
            except Exception: pass
            try:
                imap_new = _connect()
            except Exception as e2:
                return imap_ref, "NO", [f"reconnect failed: {e2}".encode()]
            try:
                typ, data = imap_new.append(mb_quoted, flags, internaldate, eml)
                return imap_new, typ, data
            except Exception as e3:
                return imap_new, "NO", [f"retry failed after reconnect: {e3}".encode()]

    success = fail = skipped = 0
    consecutive_fail = 0
    STOP_AFTER_N_CONSECUTIVE_FAIL = 10
    limit = args.limit if args.limit > 0 else len(dedup)
    t0 = datetime.datetime.now()
    for i, (src, msg_dir, folder, mid, dt) in enumerate(dedup[:limit]):
        # Proactive reconnect to dodge dovecot idle timeouts mid-run
        if i > 0 and i % RECONNECT_EVERY == 0:
            try: imap.logout()
            except Exception: pass
            try:
                imap = _connect()
                log(f"  [refresh] reconnected after {i} messages")
            except Exception as e:
                log(f"  [refresh FAIL] {e} — trying once more in 5s")
                import time; time.sleep(5)
                try: imap = _connect()
                except Exception as e2:
                    log(f"  [refresh FAIL 2] {e2} — aborting")
                    break

        mb = "INBOX" if folder in failed else folder

        # Resume-safe: skip if the message-ID is already present in the target folder
        if mid and mid in existing_ids_by_folder.get(mb, set()):
            skipped += 1
            log(f"[{i+1:4d}/{limit}] SKIP {src} {msg_dir.name} -> {mb}: already present (msg-id match)")
            continue

        enc = imap_mb_encode(mb)
        eml = build_rfc822(msg_dir)
        if eml is None:
            fail += 1
            consecutive_fail += 1
            log(f"[{i+1:4d}/{limit}] SKIP {src} {msg_dir.name} -> {mb}: build failed")
        else:
            imap, typ, data = _append_with_retry(
                imap, enc, r"(\Seen)", imaplib.Time2Internaldate(dt.timestamp()), eml
            )
            if typ == "OK":
                success += 1
                consecutive_fail = 0
                if mid:
                    existing_ids_by_folder.setdefault(mb, set()).add(mid)
                log(f"[{i+1:4d}/{limit}] OK   {src} {msg_dir.name} -> {mb} ({len(eml)}B)")
            else:
                fail += 1
                consecutive_fail += 1
                err = (data[0] if data else b"").decode("utf-8", errors="replace")
                log(f"[{i+1:4d}/{limit}] FAIL {src} {msg_dir.name} -> {mb}: {err[:160]}")

        if consecutive_fail >= STOP_AFTER_N_CONSECUTIVE_FAIL:
            log(f"  [STOP] {consecutive_fail} consecutive failures — aborting run")
            break

        if (i + 1) % 25 == 0:
            el = (datetime.datetime.now() - t0).total_seconds()
            rate = (i + 1) / max(el, 0.001)
            eta = (limit - i - 1) / max(rate, 0.001)
            log(f"  -- progress: {i+1}/{limit}  ok={success} fail={fail}  "
                f"elapsed={el:.0f}s  rate={rate:.2f}/s  eta={eta:.0f}s")

    el = (datetime.datetime.now() - t0).total_seconds()
    log(f"\n=== COMPLETE ===")
    log(f"  success: {success}")
    log(f"  skipped: {skipped} (already present from prior run)")
    log(f"  fail:    {fail}")
    log(f"  elapsed: {el:.0f}s")
    log(f"  consecutive_fail_at_end: {consecutive_fail}")

    try: imap.logout()
    except Exception: pass
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
