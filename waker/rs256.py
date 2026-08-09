"""RSASSA-PKCS1-v1_5 over SHA-256, using nothing but the standard library.

The Lambda runtime ships boto3 but neither `cryptography` nor `PyJWT`, and a
layer (or a container image) is a lot of moving parts to carry for one
signature. The primitive itself is small: parse the PEM to (n, d), pad the
digest per RFC 8017 §9.2, and do one modular exponentiation.

Only signing is implemented. Verification is GitHub's job.
"""

import base64
import hashlib

__all__ = ["private_key", "sign", "b64u"]

# DigestInfo prefix for SHA-256, RFC 8017 §9.2 note 1. Constant, so no DER
# writer is needed on the signing path.
_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")

_TAG_INTEGER = 0x02
_TAG_OCTET_STRING = 0x04
_TAG_SEQUENCE = 0x30


def b64u(raw: bytes) -> bytes:
    """base64url without padding — the JOSE alphabet."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _tlv(buf: bytes, i: int) -> tuple[int, bytes, int]:
    """Read one DER tag-length-value at `i`; return (tag, value, next index)."""
    if i + 2 > len(buf):
        raise ValueError("truncated DER")
    tag = buf[i]
    length = buf[i + 1]
    i += 2
    if length & 0x80:
        width = length & 0x7F
        if width == 0 or i + width > len(buf):
            raise ValueError("unsupported or truncated DER length")
        length = int.from_bytes(buf[i : i + width], "big")
        i += width
    end = i + length
    if end > len(buf):
        raise ValueError("DER value runs past the end of the buffer")
    return tag, buf[i:end], end


def _der_of_pem(pem: str) -> bytes:
    """Strip the armour from a PEM block and decode the body."""
    body = []
    inside = False
    for line in pem.replace("\\n", "\n").splitlines():
        line = line.strip()
        if line.startswith("-----BEGIN"):
            inside = True
            continue
        if line.startswith("-----END"):
            break
        if inside and line:
            body.append(line)
    if not body:
        raise ValueError("no PEM block found")
    return base64.b64decode("".join(body))


def private_key(pem: str) -> tuple[int, int]:
    """Return (modulus, private exponent) from a PKCS#1 or PKCS#8 RSA PEM.

    GitHub hands out PKCS#1 (`BEGIN RSA PRIVATE KEY`); anything that has been
    round-tripped through OpenSSL 3 tends to come back as PKCS#8
    (`BEGIN PRIVATE KEY`). Accept both rather than making the operator care.
    """
    tag, seq, _ = _tlv(_der_of_pem(pem), 0)
    if tag != _TAG_SEQUENCE:
        raise ValueError("expected a DER SEQUENCE at the top level")

    tag, _version, i = _tlv(seq, 0)
    if tag != _TAG_INTEGER:
        raise ValueError("expected the version INTEGER first")

    # PKCS#8: version, AlgorithmIdentifier (SEQUENCE), then the PKCS#1 key
    # wrapped in an OCTET STRING. Unwrap and re-enter.
    if seq[i] == _TAG_SEQUENCE:
        _tag, _algid, i = _tlv(seq, i)
        tag, inner, _ = _tlv(seq, i)
        if tag != _TAG_OCTET_STRING:
            raise ValueError("expected the privateKey OCTET STRING")
        tag, seq, _ = _tlv(inner, 0)
        if tag != _TAG_SEQUENCE:
            raise ValueError("expected an RSAPrivateKey SEQUENCE inside PKCS#8")
        tag, _version, i = _tlv(seq, 0)
        if tag != _TAG_INTEGER:
            raise ValueError("expected the RSAPrivateKey version INTEGER")

    # RSAPrivateKey ::= { version, modulus, publicExponent, privateExponent, ... }
    fields = []
    for _ in range(3):
        tag, value, i = _tlv(seq, i)
        if tag != _TAG_INTEGER:
            raise ValueError("expected an INTEGER in RSAPrivateKey")
        fields.append(int.from_bytes(value, "big"))
    modulus, _public_exponent, private_exponent = fields
    if modulus <= 0 or private_exponent <= 0:
        raise ValueError("degenerate RSA key")
    return modulus, private_exponent


def sign(pem: str, message: bytes) -> bytes:
    """RS256 signature over `message`, as raw bytes of length k."""
    modulus, private_exponent = private_key(pem)
    k = (modulus.bit_length() + 7) // 8
    digest_info = _SHA256_DIGEST_INFO + hashlib.sha256(message).digest()
    if k < len(digest_info) + 11:
        raise ValueError("RSA modulus is too small for a SHA-256 signature")
    padded = (
        b"\x00\x01" + b"\xff" * (k - len(digest_info) - 3) + b"\x00" + digest_info
    )
    signature = pow(int.from_bytes(padded, "big"), private_exponent, modulus)
    return signature.to_bytes(k, "big")
