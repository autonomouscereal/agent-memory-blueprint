"""Provider key shapes are redacted before a hook payload is stored (11-24, after a Gemini key reached a tool output)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_memory_hook as hook  # noqa: E402

# Canary values in each provider's shape. None of them is a real key.
CANARIES = [
    "AIza" + "Sy" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r",
    "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc",
    "rk_" + "test_" + "4eC39HqLyjWDarjtT1zdp7dc",
    "whsec_" + "test_" + "abcdefghijklmnop1234",
    "hf_" + "abcdefghijklmnopqrstuvwxyzABCDEF12",
    "xai-" + "abcdefghijklmnopqrstuvwxyz0123",
    "ghp_" + "abcdefghijklmnopqrstuvwxyz0123",
    "sk-" + "ant-api03-abcdefghijklmnopqrstuv",
]


def test_provider_keys_are_redacted():
    for canary in CANARIES:
        text = f"the key box reads {canary} and then Continue"
        out = hook.redact_secret_text(text)
        assert canary not in out, canary[:6]
        assert "<redacted-token>" in out


def test_ordinary_words_are_kept():
    text = "AIzawa is a name; sk_live is a word; hf_ alone; the docs say xai-grok"
    assert hook.redact_secret_text(text) == hook.audit_safe_text(text, None)


if __name__ == "__main__":
    test_provider_keys_are_redacted()
    test_ordinary_words_are_kept()
    print("ok")
