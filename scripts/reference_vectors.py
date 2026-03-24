#!/usr/bin/env python3
"""
CRYSTALS-Dilithium reference test vector generator.
Produces known-answer test vectors for ALL GHDL testbenches:
  - Barrett reduction (tb_barrett_reduce.vhd)
  - Modular multiply (tb_mod_mult.vhd)
  - NTT engine (tb_ntt_engine.vhd)
  - Decompose (tb_decompose.vhd)
  - Plus power2round, make_hint, use_hint (future testbenches)

Output CSV files written to scripts/ alongside this file.
Usage:
    python3 scripts/reference_vectors.py
"""

import os
import csv

# ---------------------------------------------------------------------------
# Dilithium-2 (ML-DSA-44) parameters
# ---------------------------------------------------------------------------
Q        = 8380417
N        = 256
GAMMA2   = 95232        # (Q-1)/88
ALPHA    = 190464       # 2 * GAMMA2
D        = 13           # for power2round
HALF_Q   = (Q - 1) // 2  # 4190208
BARRETT_M = 8396808     # ceil(2^46 / Q), matches dilithium_pkg

# N_INV: two values exist depending on context —
#   8347681 = 256^{-1} mod q  (dilithium_pkg, used when basemul absorbs a factor of 2)
#   8314945 = 128^{-1} mod q  (verify_ntt.py, clean 7-layer round-trip)
N_INV_PKG = 8347681  # dilithium_pkg value
N_INV_128 = pow(128, Q - 2, Q)  # 8314945

ZETAS = [
    1, 4808194, 3765607, 3761513, 5178923, 5496691, 5234739, 5178987,
    7778734, 3542485, 2682288, 2129892, 3764867, 7375178, 557458, 7159240,
    5010068, 4317364, 2663378, 6705802, 4855975, 7946292, 676590, 7044481,
    5152541, 1714295, 2453983, 1460718, 7737789, 4795319, 2815639, 2283733,
    3602218, 3182878, 2740543, 4793971, 5269599, 2101410, 3704823, 1159875,
    394148, 928749, 1095468, 4874037, 2071829, 4361428, 3241972, 2156050,
    3415069, 1759347, 7562881, 4805951, 3756790, 6444618, 6663429, 4430364,
    5483103, 3192354, 556856, 3870317, 2917338, 1853806, 3345963, 1858416,
    3073009, 1277625, 5744944, 3852015, 4183372, 5157610, 5258977, 8106357,
    2508980, 2028118, 1937570, 4564692, 2811291, 5396636, 7270901, 4158088,
    1528066, 482649, 1148858, 5418153, 7814814, 169688, 2462444, 5046034,
    4213992, 4892034, 1987814, 5183169, 1736313, 235407, 5130263, 3258457,
    5801164, 1787943, 5989328, 6125690, 3482206, 4197502, 7080401, 6018354,
    7062739, 2461387, 3035980, 621164, 3901472, 7153756, 2925816, 3374250,
    1356448, 5604662, 2683270, 5601629, 4912752, 2312838, 7727142, 7921254,
    348812, 8052569, 1011223, 6026202, 4561790, 6458164, 6143691, 1744507,
]

assert len(ZETAS) == 128, f"Expected 128 zetas, got {len(ZETAS)}"

# ---------------------------------------------------------------------------
# NTT layer schedule (7 layers, matching VHDL ntt_engine.vhd)
# ---------------------------------------------------------------------------
FWD_LAYERS = [  # (half_len, n_blocks) for layers 0..6
    (128, 1), (64, 2), (32, 4), (16, 8), (8, 16), (4, 32), (2, 64),
]
INV_LAYERS = [  # reversed order for INTT
    (2, 64), (4, 32), (8, 16), (16, 8), (32, 4), (64, 2), (128, 1),
]

# ---------------------------------------------------------------------------
# Arithmetic helpers
# ---------------------------------------------------------------------------

def barrett_reduce(x: int) -> int:
    """
    Barrett reduction matching ntt_engine.vhd inline function and barrett_reduce.vhd.

    Important precision note:
      M = ceil(2^46/Q) = 8396808.  Because M is a ceiling value, the quotient
      estimate quot = (x*M) >> 46 can occasionally overestimate floor(x/Q) by 1.
      When this happens, diff = x - quot*Q is NEGATIVE in Python but wraps in
      VHDL unsigned 47-bit arithmetic, producing an incorrect result.

      For the barrett_reduce.vhd standalone module (x_in is a raw product that
      fits in 46 bits), empirical testing shows no overestimate occurs for the
      tb_barrett_reduce.vhd test cases.  However, for intermediate NTT products
      some inputs (e.g. 3852015*5861652) DO trigger the overestimate.

      Therefore, for NTT test vectors we use exact Python modular arithmetic
      (see ntt() / intt() below) to produce canonical [0, Q-1] reference values
      that a CORRECT NTT implementation must produce.  The barrett_reduce()
      function here is used ONLY for tb_barrett_reduce and tb_mod_mult vectors.
    """
    x_ext = x * BARRETT_M
    quot  = x_ext >> 46
    diff  = x - quot * Q
    # Note: diff may be negative for certain inputs (Barrett approximation error).
    # For standalone barrett_reduce.vhd usage this does not occur within [0,(Q-1)^2].
    return diff - Q if diff >= Q else diff


def mod_add(a: int, b: int) -> int:
    s = a + b
    return s - Q if s >= Q else s


def mod_sub(a: int, b: int) -> int:
    return a - b if a >= b else a - b + Q


def mod_mult(a: int, b: int) -> int:
    """Modular multiply matching mod_mult.vhd (multiply then Barrett reduce)."""
    return barrett_reduce(a * b)


# ---------------------------------------------------------------------------
# NTT / INTT (7-layer, matching VHDL ntt_engine.vhd)
# ---------------------------------------------------------------------------

def ntt(a: list) -> list:
    """
    Forward NTT: CT butterfly, 7 layers, zeta_k starting at ZETAS[1].

    Uses exact Python modular arithmetic (% Q) rather than Barrett approximation
    to guarantee all output coefficients are canonical values in [0, Q-1].
    This is the correct mathematical reference; a correct hardware NTT should
    produce the same canonical values.
    """
    a = list(a)
    k = 1
    for half_len, n_blocks in FWD_LAYERS:
        for blk in range(n_blocks):
            base = blk * (2 * half_len)
            zeta = ZETAS[k]
            for j in range(half_len):
                lo = base + j
                hi = base + j + half_len
                t      = (zeta * a[hi]) % Q
                old_lo = a[lo]
                a[lo]  = (old_lo + t) % Q
                a[hi]  = (old_lo - t) % Q
            k += 1
    return a


def intt(a: list) -> list:
    """
    Inverse NTT: GS butterfly, 7 layers, N_INV = 128^{-1} scaling.
    Uses exact Python modular arithmetic for canonical [0, Q-1] output.
    """
    a = list(a)
    k = 127
    for half_len, n_blocks in INV_LAYERS:
        for blk in range(n_blocks):
            base = blk * (2 * half_len)
            zeta = ZETAS[k]
            zneg = Q - zeta
            for j in range(half_len):
                lo  = base + j
                hi  = base + j + half_len
                tlo = (a[lo] + a[hi]) % Q
                thi = (zneg * ((a[lo] - a[hi]) % Q)) % Q
                a[lo] = tlo
                a[hi] = thi
            k -= 1
    return [(x * N_INV_128) % Q for x in a]


# ---------------------------------------------------------------------------
# Decompose (reference matching rounding.c, GAMMA2=(Q-1)/88 branch)
# ---------------------------------------------------------------------------

def decompose(a: int):
    """
    Reference decompose matching Dilithium rounding.c for GAMMA2=(Q-1)/88.
    Returns (a1, a0) where:
      a = a1 * 2*GAMMA2 + a0  (mod q, with a0 centred in (-GAMMA2, GAMMA2])
    Note: the bitwise tricks use Python int arithmetic which handles sign
    extension correctly because Python integers are arbitrary precision.
    The expression ((43 - a1) >> 31) in Python shifts a Python int and will
    propagate the sign bit correctly for negative values.
    """
    a1 = (a + 127) >> 7
    a1 = (a1 * 11275 + (1 << 23)) >> 24
    # Clamp a1 to [0, 43]: if a1 > 43, (43-a1) is negative, bit-31 is 1
    # Python >> on signed int propagates sign, so ((43-a1)>>31) is -1 when a1>43
    # and 0 otherwise.  XOR with a1 zeroes a1 when a1>43.
    a1 ^= ((43 - a1) >> 31) & a1
    a0  = a - a1 * 2 * GAMMA2
    # Centre a0: if a0 > HALF_Q, subtract Q
    a0 -= (((HALF_Q - a0) >> 31) & Q)
    return a1, a0


def power2round(a: int):
    """
    Power2round matching Dilithium rounding.c.
    a1 = ceiling-round(a / 2^D),  a0 = a - a1 * 2^D
    """
    a1 = (a + (1 << (D - 1)) - 1) >> D   # = (a + 4095) >> 13
    a0 = a - (a1 << D)
    return a1, a0


def make_hint(a0: int, a1: int) -> int:
    """Make hint bit: 1 if rounding of a1+a0 differs from a1."""
    if a0 > GAMMA2 or a0 < -GAMMA2 or (a0 == -GAMMA2 and a1 != 0):
        return 1
    return 0


def use_hint(a: int, hint: int) -> int:
    """Use hint to correct a1 from decompose(a)."""
    a1, a0 = decompose(a)
    if hint == 0:
        return a1
    if a0 > 0:
        return 0 if a1 == 43 else a1 + 1
    else:
        return 43 if a1 == 0 else a1 - 1


# ---------------------------------------------------------------------------
# Section 1: Barrett reduction vectors
# ---------------------------------------------------------------------------

def gen_barrett_vectors():
    """
    Generate Barrett reduction test vectors matching tb_barrett_reduce.vhd.
    Inputs are products a*b (up to 46 bits), output is a*b mod q.
    The testbench uses raw x_in values (not pairs), so we record x_in and r_out.
    """
    test_cases = [
        # (x_in, description)
        (0,                 "0"),
        (Q - 1,             "q-1"),
        (Q,                 "q"),
        (2 * (Q - 1),       "2*(q-1)"),
        (17760834,          "17760834"),
        ((Q - 1) * (Q - 1), "(q-1)^2"),
        (20000,             "100*200"),
        (2 * Q,             "2*q"),
        # Additional useful cases
        (1,                 "1"),
        (Q + 1,             "q+1"),
        (3 * Q,             "3*q"),
        (1753 * 1753,       "g^2"),
        (4808194 * 1,       "zeta[1]*1"),
        (Q * Q - 1,         "q^2-1"),
    ]
    vectors = []
    for x_in, desc in test_cases:
        # Python exact mod
        r_expected = x_in % Q
        # Barrett approximation (matches VHDL)
        r_barrett  = barrett_reduce(x_in) if x_in <= (Q - 1) * (Q - 1) else x_in % Q
        vectors.append({
            "x_in": x_in,
            "r_expected": r_expected,
            "r_barrett": r_barrett,
            "description": desc,
        })
    return vectors


# ---------------------------------------------------------------------------
# Section 2: Modular multiply vectors
# ---------------------------------------------------------------------------

def gen_mod_mult_vectors():
    """
    Generate a*b mod q test vectors matching tb_mod_mult.vhd.
    Both a and b are in [0, q-1] (23-bit unsigned).
    """
    pairs = [
        (1,       1,       "1*1"),
        (2,       3,       "2*3"),
        (Q - 1,   2,       "(q-1)*2"),
        (100,     200,     "100*200"),
        (4808194, 1,       "zeta[1]*1"),
        (Q - 1,   Q - 1,   "(q-1)^2"),
        (1753,    1753,    "g^2=zeta[64]"),
        (0,       Q - 1,   "0*anything"),
        # Additional
        (ZETAS[1], ZETAS[2], "zeta[1]*zeta[2]"),
        (ZETAS[64], ZETAS[64], "zeta[64]^2"),
        (1,       Q - 1,   "1*(q-1)"),
        (GAMMA2,  2,       "gamma2*2"),
        (ALPHA,   ALPHA,   "alpha^2"),
        (131072,  131072,  "gamma1^2"),
    ]
    vectors = []
    for a, b, desc in pairs:
        r_python  = (a * b) % Q
        r_barrett = barrett_reduce(a * b)
        vectors.append({
            "a_in": a,
            "b_in": b,
            "r_expected_python": r_python,
            "r_expected_barrett": r_barrett,
            "match": r_python == r_barrett,
            "description": desc,
        })
    return vectors


# ---------------------------------------------------------------------------
# Section 3: NTT vectors — delta polynomial
# ---------------------------------------------------------------------------

def gen_ntt_delta_vectors():
    """
    NTT([1, 0, 0, ..., 0]) — 256 output coefficients.
    Expected: [1, 0, 1, 0, ...] (alternating 1 and 0, 128 pairs).
    """
    delta = [0] * N
    delta[0] = 1
    result = ntt(delta)
    return result


def gen_ntt_ramp_vectors():
    """
    NTT([0, 1, 2, ..., 255]) — 256 output coefficients.
    """
    ramp = list(range(N))
    result = ntt(ramp)
    return result


# ---------------------------------------------------------------------------
# Section 4: Decompose vectors
# ---------------------------------------------------------------------------

def gen_decompose_vectors():
    """
    Decompose test vectors matching tb_decompose.vhd expected values.
    Test values cover boundary conditions, mid-range, and special cases.
    """
    test_values = [
        0, 1, 95232, 190464, 190465, 4190208, 4190209,
        8380416, 8380415, 1000000, 2000000, 3000000,
        4000000, 5000000, 6000000, 7000000, 7500000,
        8000000, 8380000, 47616,
    ]
    # Add VHDL testbench cases from tb_decompose.vhd
    extra = [
        190463,  # T5: a=2*gamma2-1 → a1=1, a0=-1
        285696,  # T4: a=3*gamma2   → a1=1, a0=95232
    ]
    all_vals = test_values + [v for v in extra if v not in test_values]

    vectors = []
    rt_failures = []

    for a in all_vals:
        a1, a0 = decompose(a)
        # Round-trip: a == a1 * ALPHA + a0 (possibly mod q)
        reconstructed = (a1 * ALPHA + a0) % Q
        rt_ok = (reconstructed == a % Q)
        if not rt_ok:
            # Some edge cases centre mod q
            rt_ok = ((a1 * ALPHA + a0 + Q) % Q == a % Q)
        if not rt_ok:
            rt_failures.append(a)
        vectors.append({
            "a_in": a,
            "a1_expected": a1,
            "a0_expected": a0,
            "roundtrip_ok": rt_ok,
            "reconstructed": reconstructed,
        })
    return vectors, rt_failures


# ---------------------------------------------------------------------------
# Section 5: power2round vectors
# ---------------------------------------------------------------------------

def gen_power2round_vectors():
    """
    Power2round test vectors.
    a1 in [0, ceil(q / 2^D)], a0 in [-(2^(D-1)-1), 2^(D-1)].
    """
    test_values = [
        0, 1, 4095, 4096, 8191, 8192,
        1000000, 2000000, 4000000, 8000000,
        Q - 1, Q // 2, Q // 4,
        (1 << D) - 1,   # 8191 = 2^13 - 1
        (1 << D),        # 8192 = 2^13
        (1 << D) + 1,    # 8193
    ]
    vectors = []
    for a in test_values:
        a1, a0 = power2round(a)
        rt = a1 * (1 << D) + a0
        rt_ok = (rt == a)
        vectors.append({
            "a_in": a,
            "a1_expected": a1,
            "a0_expected": a0,
            "roundtrip_ok": rt_ok,
            "reconstructed": rt,
        })
    return vectors


# ---------------------------------------------------------------------------
# Section 6: make_hint / use_hint vectors
# ---------------------------------------------------------------------------

def gen_hint_vectors():
    """
    make_hint and use_hint test vectors.
    Covers: hint=0 (no correction), hint=1 rounding up, hint=1 rounding down.
    """
    # Test values for a (input to use_hint / source of a1,a0 via decompose)
    test_values = [
        0, 1, GAMMA2, GAMMA2 + 1, GAMMA2 - 1,
        ALPHA, ALPHA - 1, ALPHA + 1,
        2 * ALPHA, Q // 2, Q - 1,
        1000000, 5000000,
    ]

    # Make_hint test vectors: supply (a0, a1) pairs
    # We derive them from decompose to get natural (a0, a1) pairs
    make_hint_vectors = []
    for a in test_values:
        a1_d, a0_d = decompose(a)
        h = make_hint(a0_d, a1_d)
        make_hint_vectors.append({
            "a0_in": a0_d,
            "a1_in": a1_d,
            "hint_expected": h,
            "source_a": a,
        })

    # Also test boundary make_hint cases directly
    boundary_cases = [
        (GAMMA2,      0, 0),        # a0 == GAMMA2, a1 == 0  → hint=0
        (GAMMA2 + 1,  0, 1),        # a0 > GAMMA2             → hint=1
        (-GAMMA2,     0, 0),        # a0 == -GAMMA2, a1 == 0  → hint=0
        (-GAMMA2,     1, 1),        # a0 == -GAMMA2, a1 != 0  → hint=1
        (-GAMMA2 - 1, 0, 1),        # a0 < -GAMMA2            → hint=1
        (0,           0, 0),        # a0 == 0                 → hint=0
        (1,           5, 0),        # small positive a0       → hint=0
        (-1,          5, 0),        # small negative a0       → hint=0
    ]
    for a0_val, a1_val, h_exp in boundary_cases:
        h_got = make_hint(a0_val, a1_val)
        make_hint_vectors.append({
            "a0_in": a0_val,
            "a1_in": a1_val,
            "hint_expected": h_exp,
            "source_a": None,
            "manual_expected": h_exp,
            "got": h_got,
            "match": h_got == h_exp,
        })

    # use_hint vectors
    use_hint_vectors = []
    for a in test_values:
        for hint in (0, 1):
            result = use_hint(a, hint)
            use_hint_vectors.append({
                "a_in": a,
                "hint": hint,
                "result_expected": result,
            })

    return make_hint_vectors, use_hint_vectors


# ---------------------------------------------------------------------------
# CSV writers
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def write_csv(filename: str, rows: list, fieldnames: list):
    path = os.path.join(SCRIPT_DIR, filename)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames,
                                extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    return path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    sep = "=" * 68

    # -----------------------------------------------------------------------
    # 1. Barrett reduction vectors
    # -----------------------------------------------------------------------
    print(sep)
    print("SECTION 1: Barrett Reduction Vectors")
    print(sep)
    barrett_vecs = gen_barrett_vectors()
    print(f"{'x_in':>20}  {'r_expected':>12}  {'r_barrett':>12}  description")
    print("-" * 68)
    mismatch_count = 0
    for v in barrett_vecs:
        match = "OK" if v["r_expected"] == v["r_barrett"] else "MISMATCH"
        if match == "MISMATCH":
            mismatch_count += 1
        print(f"{v['x_in']:>20}  {v['r_expected']:>12}  {v['r_barrett']:>12}"
              f"  {v['description']}  {match}")
    print(f"\n  Barrett mismatches vs Python exact: {mismatch_count} "
          f"(expected 0 for valid input range)")

    barrett_path = write_csv("vectors_barrett.csv", barrett_vecs,
                             ["x_in", "r_expected", "r_barrett", "description"])
    print(f"  Written: {barrett_path}")

    # -----------------------------------------------------------------------
    # 2. Modular multiply vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 2: Modular Multiply Vectors (a * b mod q)")
    print(sep)
    mult_vecs = gen_mod_mult_vectors()
    print(f"{'a_in':>10}  {'b_in':>10}  {'r_python':>12}  {'r_barrett':>12}"
          f"  description")
    print("-" * 68)
    mult_mismatch = 0
    for v in mult_vecs:
        match = "OK" if v["match"] else "MISMATCH"
        if not v["match"]:
            mult_mismatch += 1
        print(f"{v['a_in']:>10}  {v['b_in']:>10}  "
              f"{v['r_expected_python']:>12}  {v['r_expected_barrett']:>12}"
              f"  {v['description']}  {match}")
    print(f"\n  Python vs Barrett mismatches: {mult_mismatch}")

    mult_path = write_csv("vectors_mod_mult.csv", mult_vecs,
                          ["a_in", "b_in", "r_expected_python",
                           "r_expected_barrett", "match", "description"])
    print(f"  Written: {mult_path}")

    # -----------------------------------------------------------------------
    # 3. NTT delta vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 3: NTT([1, 0, ..., 0]) — delta polynomial (256 coefficients)")
    print(sep)
    print("  Note: uses exact modular arithmetic. Correct VHDL output must match.")
    ntt_delta = gen_ntt_delta_vectors()
    print(f"  First 16:  {ntt_delta[:16]}")
    print(f"  Last  16:  {ntt_delta[240:]}")
    # Structural check: [1, 0] repeated 128 times
    alt_ok = all(ntt_delta[2*i] == 1 for i in range(128)) and \
             all(ntt_delta[2*i+1] == 0 for i in range(128))
    print(f"  Pattern [1,0]x128: {'PASS' if alt_ok else 'FAIL'}")
    # Round-trip
    rt_delta = intt(ntt_delta)
    rt_ok = rt_delta[0] == 1 and all(x == 0 for x in rt_delta[1:])
    print(f"  INTT round-trip:   {'PASS' if rt_ok else 'FAIL'}")
    if not rt_ok:
        bad = [(i, rt_delta[i]) for i in range(N)
               if (i == 0 and rt_delta[i] != 1) or (i > 0 and rt_delta[i] != 0)]
        print(f"  Mismatches: {bad[:8]}")

    delta_rows = [{"index": i, "coefficient": ntt_delta[i]}
                  for i in range(N)]
    delta_path = write_csv("vectors_ntt_delta.csv", delta_rows,
                           ["index", "coefficient"])
    print(f"  Written: {delta_path}")

    # -----------------------------------------------------------------------
    # 4. NTT ramp vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 4: NTT([0, 1, 2, ..., 255]) — ramp polynomial")
    print(sep)
    print("  Note: uses exact modular arithmetic; all coefficients in [0, Q-1].")
    ntt_ramp = gen_ntt_ramp_vectors()
    print(f"  First 16:  {ntt_ramp[:16]}")
    print(f"  Last  16:  {ntt_ramp[240:]}")
    rt_ramp = intt(ntt_ramp)
    rt_ramp_ok = all(rt_ramp[i] == i for i in range(N))
    print(f"  INTT round-trip:   {'PASS' if rt_ramp_ok else 'FAIL'}")
    if not rt_ramp_ok:
        bad = [(i, rt_ramp[i]) for i in range(N) if rt_ramp[i] != i]
        print(f"  Mismatches: {bad[:8]}")

    ramp_rows = [{"index": i, "coefficient": ntt_ramp[i]}
                 for i in range(N)]
    ramp_path = write_csv("vectors_ntt_ramp.csv", ramp_rows,
                          ["index", "coefficient"])
    print(f"  Written: {ramp_path}")

    # -----------------------------------------------------------------------
    # 5. Decompose vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 5: Decompose Vectors")
    print(sep)
    print(f"  ALPHA = 2*GAMMA2 = {ALPHA},  GAMMA2 = {GAMMA2},  HALF_Q = {HALF_Q}")
    print()
    decompose_vecs, rt_failures = gen_decompose_vectors()
    print(f"{'a_in':>10}  {'a1':>5}  {'a0':>10}  {'reconstruct':>12}  rt")
    print("-" * 55)
    for v in decompose_vecs:
        rt_str = "OK" if v["roundtrip_ok"] else "FAIL"
        print(f"{v['a_in']:>10}  {v['a1_expected']:>5}  {v['a0_expected']:>10}"
              f"  {v['reconstructed']:>12}  {rt_str}")

    print()
    print(f"  Round-trip failures: {len(rt_failures)}")
    if rt_failures:
        print(f"  Failed values: {rt_failures}")

    # Verify specific tb_decompose.vhd expected values
    print()
    print("  Cross-check vs tb_decompose.vhd expected values:")
    tb_cases = [
        (0,       0,  0,    "T1: a=0"),
        (190464,  1,  0,    "T2: a=2*gamma2"),
        (95232,   0,  95232,"T3: a=gamma2"),
        (285696,  1,  95232,"T4: a=3*gamma2"),
        (190463,  1, -1,    "T5: a=2g2-1"),
        (8380416, 0, -1,    "T6: a=q-1"),
    ]
    all_match = True
    for a_val, a1_exp, a0_exp, label in tb_cases:
        a1_got, a0_got = decompose(a_val)
        match = (a1_got == a1_exp) and (a0_got == a0_exp)
        status = "PASS" if match else "FAIL"
        if not match:
            all_match = False
        print(f"    {label:<22}: a1={a1_got} (exp {a1_exp}), "
              f"a0={a0_got} (exp {a0_exp})  [{status}]")
    print(f"  All tb_decompose.vhd cases: {'PASS' if all_match else 'FAIL'}")

    decomp_path = write_csv("vectors_decompose.csv", decompose_vecs,
                            ["a_in", "a1_expected", "a0_expected",
                             "roundtrip_ok", "reconstructed"])
    print(f"\n  Written: {decomp_path}")

    # -----------------------------------------------------------------------
    # 6. power2round vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 6: Power2Round Vectors  (D=13, 2^D=8192)")
    print(sep)
    p2r_vecs = gen_power2round_vectors()
    print(f"{'a_in':>10}  {'a1':>8}  {'a0':>8}  {'reconstruct':>12}  rt")
    print("-" * 52)
    p2r_failures = 0
    for v in p2r_vecs:
        rt_str = "OK" if v["roundtrip_ok"] else "FAIL"
        if not v["roundtrip_ok"]:
            p2r_failures += 1
        print(f"{v['a_in']:>10}  {v['a1_expected']:>8}  {v['a0_expected']:>8}"
              f"  {v['reconstructed']:>12}  {rt_str}")
    print(f"\n  Round-trip failures: {p2r_failures}")

    p2r_path = write_csv("vectors_power2round.csv", p2r_vecs,
                         ["a_in", "a1_expected", "a0_expected",
                          "roundtrip_ok", "reconstructed"])
    print(f"  Written: {p2r_path}")

    # -----------------------------------------------------------------------
    # 7. make_hint / use_hint vectors
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SECTION 7: make_hint / use_hint Vectors")
    print(sep)
    make_hint_vecs, use_hint_vecs = gen_hint_vectors()

    # Print make_hint summary (boundary manual cases)
    print("  make_hint boundary cases:")
    boundary_rows = [v for v in make_hint_vecs if v.get("source_a") is None]
    print(f"  {'a0_in':>10}  {'a1_in':>6}  {'expected':>9}  {'got':>5}  match")
    print("  " + "-" * 45)
    mh_failures = 0
    for v in boundary_rows:
        match_str = "OK" if v.get("match", True) else "FAIL"
        if not v.get("match", True):
            mh_failures += 1
        print(f"  {v['a0_in']:>10}  {v['a1_in']:>6}  "
              f"{v['hint_expected']:>9}  {v.get('got', '?'):>5}  {match_str}")
    print(f"\n  make_hint boundary failures: {mh_failures}")

    print()
    print(f"  use_hint sample (first 10):")
    print(f"  {'a_in':>10}  {'hint':>5}  {'result':>8}")
    print("  " + "-" * 28)
    for v in use_hint_vecs[:10]:
        print(f"  {v['a_in']:>10}  {v['hint']:>5}  {v['result_expected']:>8}")

    # Write make_hint CSV (only from decompose-derived rows for clean interface)
    decomp_rows = [v for v in make_hint_vecs if v.get("source_a") is not None]
    mh_path = write_csv("vectors_make_hint.csv", decomp_rows,
                        ["a0_in", "a1_in", "hint_expected", "source_a"])
    uh_path = write_csv("vectors_use_hint.csv", use_hint_vecs,
                        ["a_in", "hint", "result_expected"])
    print(f"\n  Written: {mh_path}")
    print(f"  Written: {uh_path}")

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    print()
    print(sep)
    print("SUMMARY")
    print(sep)
    total_issues = mismatch_count + mult_mismatch + \
                   (0 if rt_ok else 1) + (0 if rt_ramp_ok else 1) + \
                   len(rt_failures) + p2r_failures + mh_failures
    print(f"  Barrett mismatches:          {mismatch_count}")
    print(f"  Mod-mult mismatches:         {mult_mismatch}")
    print(f"  NTT delta round-trip:        {'PASS' if rt_ok else 'FAIL'}")
    print(f"  NTT ramp round-trip:         {'PASS' if rt_ramp_ok else 'FAIL'}")
    print(f"  Decompose RT failures:       {len(rt_failures)}")
    print(f"  Power2round RT failures:     {p2r_failures}")
    print(f"  make_hint boundary failures: {mh_failures}")
    print()
    if total_issues == 0:
        print("  ALL VECTORS GENERATED SUCCESSFULLY — NO MISMATCHES")
    else:
        print(f"  WARNING: {total_issues} issue(s) detected — review output above")
    print()
    print("  CSV files written to scripts/:")
    for name in [
        "vectors_barrett.csv",
        "vectors_mod_mult.csv",
        "vectors_ntt_delta.csv",
        "vectors_ntt_ramp.csv",
        "vectors_decompose.csv",
        "vectors_power2round.csv",
        "vectors_make_hint.csv",
        "vectors_use_hint.csv",
    ]:
        print(f"    {name}")
    print(sep)


if __name__ == "__main__":
    main()
