#!/usr/bin/env node
// Convert an IPFS CID between v0 (base58btc "Qm...") and v1 (base32 "bafy...").
// Dependency-free. Prints "cid_v0=<...>\ncid_v1=<...>" so callers can eval it.
//
// Usage: node cid-convert.mjs <cid>

const B58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
const B32_ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567' // RFC4648 lower, no padding

function baseDecode(str, alphabet) {
  const base = alphabet.length
  const bytes = [0]
  for (const ch of str) {
    const value = alphabet.indexOf(ch)
    if (value === -1) throw new Error(`Invalid character "${ch}" for base${base}`)
    let carry = value
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j] * base
      bytes[j] = carry & 0xff
      carry >>= 8
    }
    while (carry > 0) {
      bytes.push(carry & 0xff)
      carry >>= 8
    }
  }
  // Account for leading zero "digits" (preserve leading-zero bytes).
  for (const ch of str) {
    if (ch === alphabet[0]) bytes.push(0)
    else break
  }
  return Uint8Array.from(bytes.reverse())
}

function baseEncode(bytes, alphabet) {
  const base = alphabet.length
  const digits = [0]
  for (const byte of bytes) {
    let carry = byte
    for (let j = 0; j < digits.length; j++) {
      carry += digits[j] << 8
      digits[j] = carry % base
      carry = (carry / base) | 0
    }
    while (carry > 0) {
      digits.push(carry % base)
      carry = (carry / base) | 0
    }
  }
  let out = ''
  for (const byte of bytes) {
    if (byte === 0) out += alphabet[0]
    else break
  }
  for (let k = digits.length - 1; k >= 0; k--) out += alphabet[digits[k]]
  return out
}

function base32Encode(bytes, alphabet) {
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      out += alphabet[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }
  if (bits > 0) out += alphabet[(value << (5 - bits)) & 31]
  return out
}

function base32Decode(str, alphabet) {
  let bits = 0
  let value = 0
  const out = []
  for (const ch of str) {
    const idx = alphabet.indexOf(ch)
    if (idx === -1) throw new Error(`Invalid base32 character "${ch}"`)
    value = (value << 5) | idx
    bits += 5
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff)
      bits -= 8
    }
  }
  return Uint8Array.from(out)
}

const DAG_PB = 0x70 // multicodec content type for dag-pb
const SHA2_256 = 0x12 // multihash hash function code
const SHA2_256_LEN = 0x20 // 32 bytes

// Read an unsigned LEB128 varint at `offset`. Returns { value, length }.
function readVarint(bytes, offset) {
  let value = 0
  let shift = 0
  let length = 0
  for (;;) {
    if (offset + length >= bytes.length) throw new Error('Truncated varint')
    const byte = bytes[offset + length]
    value += (byte & 0x7f) * 2 ** shift
    length += 1
    if ((byte & 0x80) === 0) break
    shift += 7
    if (shift > 35) throw new Error('Varint too long')
  }
  return { value, length }
}

// Validate a dag-pb sha2-256 multihash (0x12 0x20 + 32 bytes) and return it.
function assertDagPbMultihash(mh) {
  if (mh.length !== 34 || mh[0] !== SHA2_256 || mh[1] !== SHA2_256_LEN) {
    throw new Error('Expected a dag-pb sha2-256 multihash (0x12 0x20 + 32 bytes)')
  }
  return mh
}

// Extract the dag-pb sha2-256 multihash (0x12 0x20 + 32 bytes) from any CID form.
function multihashFromCid(cid) {
  if (cid.startsWith('Qm')) {
    // CIDv0 is the bare dag-pb sha2-256 multihash, base58btc-encoded.
    return assertDagPbMultihash(baseDecode(cid, B58_ALPHABET))
  }
  if (cid.startsWith('b')) {
    // CIDv1 base32: <version><codec><multihash>, version and codec are varints.
    const bytes = base32Decode(cid.slice(1), B32_ALPHABET)
    const version = readVarint(bytes, 0)
    if (version.value !== 1) throw new Error('Only CIDv1 base32 is supported')
    const codec = readVarint(bytes, version.length)
    if (codec.value !== DAG_PB) {
      throw new Error(`Unsupported CIDv1 codec 0x${codec.value.toString(16)} (expected dag-pb 0x70)`)
    }
    return assertDagPbMultihash(bytes.slice(version.length + codec.length))
  }
  throw new Error(`Unsupported CID format: ${cid}`)
}

const input = process.argv[2]
if (!input) {
  console.error('Usage: node cid-convert.mjs <cid>')
  process.exit(1)
}

const mh = multihashFromCid(input)
const cidV0 = baseEncode(mh, B58_ALPHABET)
const cidV1 = 'b' + base32Encode(Uint8Array.from([0x01, 0x70, ...mh]), B32_ALPHABET)

process.stdout.write(`cid_v0=${cidV0}\ncid_v1=${cidV1}\n`)
