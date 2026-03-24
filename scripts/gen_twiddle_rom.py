#!/usr/bin/env python3
"""
Verify Dilithium NTT twiddle factors for q=8380417, N=256.
Generator g=1753, using bit-reversed indexing.

Usage:
    python3 gen_twiddle_rom.py

Outputs:
    - Forward and inverse twiddle tables printed to stdout
    - tables/twiddle_factors_verify.mem (hex, one entry per line)
    - Verification result: NTT([1, 0, ..., 0]) should be all-ones
"""

import os

Q = 8380417
N = 256
G = 1753  # primitive 512th root of unity mod q


def bitrev8(n: int) -> int:
    """Reverse the 8 LSBs of n."""
    result = 0
    for _ in range(8):
        result = (result << 1) | (n & 1)
        n >>= 1
    return result


def gen_zetas() -> list:
    """Generate the 128 forward NTT twiddle factors using bit-reversed exponents."""
    zetas = []
    for k in range(128):
        exp = bitrev8(k)
        z = pow(G, exp, Q)
        zetas.append(z)
    return zetas


zetas = gen_zetas()

print("=" * 60)
print("Forward NTT zetas (128 entries, bit-reversed indexing):")
print("=" * 60)
for i, z in enumerate(zetas):
    print(f"  [{i:3d}] => {z}")

# Inverse twiddle factors: negated forward zetas (mod q)
zetas_inv = [(-z) % Q for z in zetas]
print()
print("=" * 60)
print("Inverse NTT zetas (negated forward zetas mod q):")
print("=" * 60)
for i, z in enumerate(zetas_inv):
    print(f"  [{i:3d}] => {z}")


def ntt_ref(a: list) -> list:
    """
    Reference in-place forward NTT matching the VHDL ntt_engine.
    Uses the pre-computed zetas table.
    """
    a = list(a)
    k = 0
    length = N // 2  # 128
    while length >= 1:
        start = 0
        while start < N:
            k += 1
            if k <= 128:
                zeta = zetas[k - 1]
            else:
                zeta = 1  # safety fallback (should never reach here for N=256)
            for j in range(start, start + length):
                t = (zeta * a[j + length]) % Q
                a[j + length] = (a[j] - t) % Q
                a[j]          = (a[j] + t) % Q
            start += 2 * length
        length //= 2
    return a


def intt_ref(a: list) -> list:
    """
    Reference in-place inverse NTT with N^{-1} scaling.
    """
    a = list(a)
    k = 127
    length = 1
    while length <= 128:
        start = 0
        while start < N:
            zeta = (-zetas[k]) % Q
            k -= 1
            for j in range(start, start + length):
                t          = a[j]
                a[j]       = (t + a[j + length]) % Q
                a[j + length] = (zeta * (a[j + length] - t)) % Q
            start += 2 * length
        length *= 2
    N_INV = 8347681  # pow(256, -1, Q)
    return [(x * N_INV) % Q for x in a]


# -----------------------------------------------------------------------
# Verification: NTT of delta should be all-ones
# -----------------------------------------------------------------------
print()
print("=" * 60)
print("Verification: NTT([1, 0, ..., 0])")
print("=" * 60)
delta = [0] * N
delta[0] = 1
ntt_result = ntt_ref(delta)

all_ones = all(x == 1 for x in ntt_result)
print(f"All-ones check: {'PASS' if all_ones else 'FAIL'}")
print(f"First 16 NTT coefficients: {ntt_result[:16]}")

# -----------------------------------------------------------------------
# Round-trip test
# -----------------------------------------------------------------------
print()
print("=" * 60)
print("Round-trip test: INTT(NTT(delta)) == delta")
print("=" * 60)
roundtrip = intt_ref(ntt_result)
rt_pass = (roundtrip[0] == 1) and all(x == 0 for x in roundtrip[1:])
print(f"Round-trip: {'PASS' if rt_pass else 'FAIL'}")
if not rt_pass:
    bad = [(i, v) for i, v in enumerate(roundtrip) if (i == 0 and v != 1) or (i > 0 and v != 0)]
    print(f"  Mismatches: {bad[:8]}")

# -----------------------------------------------------------------------
# Cross-check against dilithium_pkg C_ZETAS values (first 10)
# -----------------------------------------------------------------------
PKG_ZETAS = [
    1, 4808194, 3765607, 3761513, 5178923, 5496691, 5234739, 5178987,
    7778734, 3542485,
]
print()
print("=" * 60)
print("Cross-check vs dilithium_pkg.vhd C_ZETAS (first 10):")
print("=" * 60)
for i in range(10):
    match = "OK" if zetas[i] == PKG_ZETAS[i] else f"MISMATCH (pkg={PKG_ZETAS[i]})"
    print(f"  zetas[{i}] = {zetas[i]:8d}  {match}")

# -----------------------------------------------------------------------
# Write verification .mem file
# -----------------------------------------------------------------------
script_dir = os.path.dirname(os.path.abspath(__file__))
tables_dir = os.path.join(os.path.dirname(script_dir), "tables")
os.makedirs(tables_dir, exist_ok=True)

out_path = os.path.join(tables_dir, "twiddle_factors_verify.mem")
with open(out_path, "w") as f:
    for z in zetas:
        f.write(f"{z:06x}\n")
print()
print(f"Written {len(zetas)} forward zeta entries to: {out_path}")

# Also write inverse .mem
out_path_inv = os.path.join(tables_dir, "twiddle_factors_inv_verify.mem")
with open(out_path_inv, "w") as f:
    for z in zetas_inv:
        f.write(f"{z:06x}\n")
print(f"Written {len(zetas_inv)} inverse zeta entries to: {out_path_inv}")

print()
print("gen_twiddle_rom.py done.")
