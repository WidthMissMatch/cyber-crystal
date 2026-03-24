# CRYSTALS-Kyber (ML-KEM) on FPGA — Kyber-512

**Standard:** CRYSTALS-Kyber / ML-KEM (FIPS 203, selected by NIST 2024)
**Target:** Xilinx Zynq UltraScale+ ZCU106 (`xczu7ev-ffvc1156-2-e`)
**Language:** VHDL-2008
**Variant:** Kyber-512 (security level 1 — ~AES-128 equivalent)
**Key Primitive:** Number Theoretic Transform (NTT) over Z_q, q = 3329

A hardware implementation of CRYSTALS-Kyber, the post-quantum key encapsulation mechanism (KEM) standardized by NIST as ML-KEM. The design implements KeyGen and Encapsulation operations with dual parallel NTT engines, dual noise generators, and a 16-BRAM polynomial storage bank.

---

## Why Kyber? Post-Quantum Cryptography

Current public-key cryptography (RSA, ECC, X25519) relies on the hardness of:
- **Integer factorization** (RSA) → broken by Shor's algorithm on quantum computers
- **Discrete logarithm** (ECC) → broken by Shor's algorithm on quantum computers

Kyber's security relies on the **Module Learning With Errors (MLWE)** problem:

```
Given:  A (random matrix), b = A·s + e   (s = secret, e = small noise)
Find:   s

This is hard classically AND on quantum computers.
No known quantum speedup beyond sqrt (Grover's on brute force).
```

NIST standardized Kyber as **FIPS 203 (ML-KEM)** in August 2024, making it the first post-quantum KEM standard. This FPGA implementation targets the same security level as AES-128.

---

## What Kyber Does — The Three Operations

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        KYBER KEY EXCHANGE                               │
│                                                                         │
│   ALICE (Server)                        BOB (Client)                    │
│                                                                         │
│   ┌─────────────┐                       ┌────────────────────────┐      │
│   │   KeyGen    │                       │     Encapsulate        │      │
│   │             │  ─── public key ───>  │                        │      │
│   │  pk, sk ←   │                       │  ciphertext, K ←       │      │
│   │  A,t = A·s+e│  <─ ciphertext ────   │  u = A^T·r+e1          │      │
│   └─────────────┘                       │  v = t^T·r+e2+encode(m)│      │
│                                         └────────────────────────┘      │
│   ┌─────────────┐                                                       │
│   │  Decapsulate│                                                       │
│   │  K = decode(│                                                       │
│   │   v - s^T·u)│  ══ K (shared secret) ══ K                            │
│   └─────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

Both sides arrive at the same secret key **K** without ever transmitting it.

---

## Kyber-512 Parameters

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `N` | 256 | Polynomial degree |
| `q` | **3329** | Modulus (prime, NTT-friendly) |
| `k` | 2 | Module rank (matrix dimension) |
| `η₁` | 3 | Noise distribution width (KeyGen) |
| `η₂` | 2 | Noise distribution width (Encaps) |
| `dᵤ` | 10 | Ciphertext compression bits (u) |
| `d_v` | 4 | Ciphertext compression bits (v) |
| Security | Level 1 | ~AES-128 equivalent |

All arithmetic is in the ring **Z_q[x] / (x^256 + 1)** — polynomials of degree < 256 with 12-bit coefficients mod 3329.

---

## Hardware Architecture

### System Overview

```
                        ┌─────────────────────────────────────────────────┐
                        │                  kyber_top                      │
                        │                                                 │
  clk, rst              │                                                 │
  start, mode[1:0] ──>  │  ┌────────────────────────────────────────────┐ │
  seed[63:0]            │  │        16 × poly_bram_4port                │ │
  message[31:0]         │  │   BRAM[0..15]: 256 × 12-bit coefficients   │ │
                        │  │   4-port: 2 read + 2 write simultaneously  │ │
  done, busy      <──   │  └──────────────┬───────────────────────────┬─┘ │
  dbg_data[11:0]  <──   │                 │ shared BRAM bus           │   │
                        │   ┌─────────────┴────┐   ┌──────────────────┴┐  │
                        │   │  keygen_ctrl     │   │  encaps_ctrl      │  │
                        │   │  (mode = "00")   │   │  (mode = "01")    │  │
                        │   └────────┬─────────┘   └──────┬────────────┘  │
                        │            │ arbitrates          │              │
                        │   ┌────────▼─────────────────────▼────────────┐ │
                        │   │              Compute Engines              │ │
                        │   │                                           │ │
                        │   │  ntt_pipeline ×2    (NTT / INTT)          │ │
                        │   │  poly_noise_gen ×2  (CBD sampler)         │ │
                        │   │  poly_basemul ×2    (NTT-domain multiply) │ │
                        │   │  poly_add           (poly addition)       │ │
                        │   │  compress           (coefficient encoding)│ │
                        │   └───────────────────────────────────────────┘ │
                        └─────────────────────────────────────────────────┘
```

### 16-BRAM Polynomial Storage

Each polynomial (256 × 12-bit coefficients) occupies one BRAM. The 16 BRAMs store:

| BRAM Index | KeyGen usage | Encaps usage |
|-----------|-------------|-------------|
| 0–1 | Secret key `s` (k=2 polys) | Randomness `r` |
| 2–3 | Public matrix `A` row 0, 1 | Public matrix `A` |
| 4–5 | Noise `e` | Noise `e1, e2` |
| 6–7 | Public key `t = A·s + e` | Ciphertext `u` |
| 8–15 | Intermediate / scratch | `v`, scratch |

All BRAMs have **4 ports** (2 read + 2 write), allowing two compute engines to access different polynomials simultaneously without contention.

---

## Module-by-Module Explanation

### 1. `kyber_pkg.vhd` — Package and Constants

Defines all Kyber-512 parameters and the 128-entry twiddle factor tables:

```vhdl
constant KYBER_Q : positive := 3329;         -- prime modulus
constant BARRETT_M : unsigned := 5039;        -- Barrett: floor(2^24 / 3329)
constant N_INV : unsigned := 3303;            -- 128^-1 mod 3329 (INTT scaling)
constant C_ZETAS : t_twiddle_rom := (...);    -- 128 forward NTT twiddle factors
constant C_ZETAS_INV : t_twiddle_rom := (...); -- 128 inverse NTT twiddle factors
```

**Why 3329?** It is NTT-friendly: `3329 - 1 = 3328 = 2^8 × 13`, so the multiplicative group contains a 256th root of unity, enabling NTT of length 256.

---

### 2. Modular Arithmetic — `src/mod_arith/`

#### `barrett_reduce.vhd` — Fast mod-3329 reduction

Instead of hardware division, uses Barrett reduction:
```
r = a - q × floor(a × m / 2^24)   where m = floor(2^24 / q) = 5039
```
This replaces a 12÷12-bit division with two multiplications and a subtraction — no divider needed.

#### `mod_mult.vhd` — 12×12-bit multiply mod 3329

Computes `(a × b) mod 3329` using Barrett reduction on the 24-bit product.

#### `mod_add_sub.vhd` — Conditional modular add/subtract

```
add: if a+b >= q then a+b-q else a+b
sub: if a-b < 0 then a-b+q else a-b
```
Single-cycle, no multiplier needed.

---

### 3. NTT Engine — `src/ntt/`

The **Number Theoretic Transform** is the key to Kyber's efficiency. It converts polynomial multiplication from O(N²) to O(N log N):

```
Normal:  multiply two degree-255 polynomials = 256² = 65,536 multiplications
NTT:     forward NTT → pointwise multiply → inverse NTT = 3 × 256×log(256)/2 ≈ 3,072
Speedup: ~21×
```

#### `butterfly_ct.vhd` — Cooley-Tukey butterfly (forward NTT)

```
Given: a, b, zeta (twiddle factor)
Output:
  a' = a + zeta × b  (mod q)
  b' = a - zeta × b  (mod q)
```

#### `butterfly_gs.vhd` — Gentleman-Sande butterfly (inverse NTT)

```
Given: a, b, zeta
Output:
  a' = a + b          (mod q)
  b' = zeta × (a - b) (mod q)
```

#### `ntt_engine.vhd` — 7-stage iterative NTT

Processes all 7 levels of the NTT butterfly network sequentially. Each level halves the butterfly stride.

#### `ntt_pipeline.vhd` — 4-port BRAM interface wrapper

Wraps `ntt_engine` with a BRAM interface using 2 read + 2 write ports for in-place NTT:

```
Level 0: stride=128  → read pairs (0,128), (1,129), ..., butterfly, write back
Level 1: stride=64   → read pairs (0,64), (1,65), ...
...
Level 6: stride=1    → read pairs (0,1), (2,3), ...
```

#### `twiddle_rom.vhd` — 128-entry twiddle factor ROM

Pre-computed ζ^k values in bit-reversed order. Also stored in `tables/twiddle_factors.mem` and `twiddle_factors_inv.mem` for simulation loading.

---

### 4. Polynomial Operations — `src/poly/`

#### `poly_bram_4port.vhd` — Dual-port BRAM with 2 read + 2 write

```vhdl
-- Read port 1 & 2: purely combinational (1-cycle latency)
-- Write port 1 & 2: registered write enable
-- Allows NTT to read two coefficients and write two results per cycle
```

#### `poly_basemul.vhd` — Pointwise multiplication in NTT domain

After NTT, polynomials are multiplied pointwise. In Kyber's NTT (degree-2 residues):
```
For each pair (i, i+128):
  (a0, a1) × (b0, b1) = (a0·b0 + zeta·a1·b1,  a0·b1 + a1·b0)   mod q
```

#### `poly_add.vhd` / `poly_sub.vhd` — Coefficient-wise add/subtract

Streams through all 256 coefficients, applying `mod_add_sub` each cycle. 256-cycle latency.

---

### 5. Sampling — `src/sampling/`

#### `lfsr_prng.vhd` — 64-bit LFSR pseudo-random generator

Generates pseudo-random bits from a 64-bit seed using a maximal-length LFSR. Used to simulate the hash-based sampling of Kyber (SHAKE-128/256 is replaced by LFSR for PoC hardware simplicity).

#### `cbd_sampler.vhd` — Centered Binomial Distribution sampler

Kyber's noise is not Gaussian but **CBD(η)**:
```
coefficient = Σ(a_i) - Σ(b_i)   for i = 0..η-1
where a_i, b_i are independent uniform bits
```
For η=3: each coefficient ∈ {-3,-2,-1,0,1,2,3} with binomial distribution.

#### `poly_noise_gen.vhd` — Full polynomial noise sampler

Drives the LFSR and CBD sampler to fill a complete 256-coefficient polynomial with noise. Takes a seed and BRAM destination selector.

---

### 6. Codec — `src/codec/`

#### `compress.vhd` — Coefficient compression

Reduces coefficient bit-width for transmission:
```
Compress(x, d) = round(2^d / q × x) mod 2^d
```
- `dᵤ = 10` bits for ciphertext polynomial `u` (from 12 bits)
- `d_v = 4` bits for ciphertext scalar `v` (from 12 bits)

This lossy compression is part of Kyber's security/bandwidth trade-off.

#### `decompress.vhd` — Coefficient decompression

Inverse: `Decompress(x, d) = round(q / 2^d × x)`

---

### 7. Controllers — `src/top/`

#### `keygen_controller.vhd` — KeyGen FSM

Implements the Kyber KeyGen algorithm:

```
KeyGen(seed):
  1. Sample matrix A from seed (uniform random)
  2. Sample secret s = CBD(η₁) from seed      ← noise_gen 1
  3. Sample error  e = CBD(η₁) from seed      ← noise_gen 2
  4. NTT(s), NTT(e)                           ← ntt1 and ntt2 in parallel
  5. t = A·s + e  (in NTT domain)
     = basemul(A, NTT(s)) + NTT(e)           ← basemul1 and basemul2 in parallel
  6. Public key  = (A, t)
     Secret key  = s

Output: pk = (seed_A, t),  sk = s
```

#### `encaps_controller.vhd` — Encapsulation FSM

Implements the Kyber Encaps algorithm:

```
Encaps(pk, message):
  1. Sample randomness r = CBD(η₁)            ← noise_gen 1
  2. Sample noise e1 = CBD(η₂), e2 = CBD(η₂) ← noise_gen 2
  3. NTT(r)                                   ← ntt1
  4. u = A^T·r + e1  (in NTT domain)
     = INTT(basemul(A, NTT(r))) + e1          ← basemul1 + basemul2 in parallel
  5. v = t^T·r + e2 + encode(message)
     = INTT(basemul(t, NTT(r))) + e2 + msg
  6. Compress u to dᵤ bits
     Compress v to d_v bits
  7. Ciphertext = (u, v)
     Shared secret K = H(message)
```

#### `kyber_top.vhd` — Top-level with BRAM routing

The top-level connects all compute engines to the 16-BRAM bank via a combinational routing process. The key insight: with 4-port BRAMs and dual engines, **NTT1 and NTT2 can run on different polynomials simultaneously**, halving the time for parallel operations.

**Mode control:**
```vhdl
mode = "00"  →  KeyGen
mode = "01"  →  Encaps
```

---

## Signal Flow Diagrams

### KeyGen Pipeline

```
Clock → 0         1         2         3         4         5
        │ IDLE    │ GEN_A   │ SAMPLE_S │ SAMPLE_E│ NTT_SE  │ BASEMUL │
        │         │         │ (noise1) │ (noise2)│ ntt1(s) │ A·s + e │
        │         │         │ parallel │ parallel│ ntt2(e) │ → t     │
        │         │ BRAM0   │ BRAM2    │ BRAM3   │ BRAM2,3 │ BRAM4,5 │
        └─────────┴─────────┴──────────┴─────────┴─────────┴─────────┘
                                                   ↑ dual NTT parallel
```

### NTT Butterfly Network (256-point, 7 levels)

```
Input:  a[0], a[1], ..., a[255]  (in bit-reversed order)

Level 0 (stride 128):
  a[0]   ←── butterfly(a[0],   a[128], ζ[1])
  a[128] ←──
  a[1]   ←── butterfly(a[1],   a[129], ζ[1])
  ...

Level 1 (stride 64):
  a[0]   ←── butterfly(a[0],   a[64],  ζ[2])
  a[64]  ←──
  ...

Level 6 (stride 1):
  a[0]   ←── butterfly(a[0],   a[1],   ζ[64])
  a[2]   ←── butterfly(a[2],   a[3],   ζ[65])
  ...

Output: a[0..255] in NTT domain (pointwise multiplication domain)
```

---

## Repository Structure

```
cyber-crystal/
│
├── src/                          — 22 VHDL source files
│   ├── kyber_pkg.vhd             ← Package: q=3329, params, twiddle tables
│   │
│   ├── mod_arith/                ← Modular arithmetic primitives
│   │   ├── barrett_reduce.vhd   ← Fast mod-3329 (no divider)
│   │   ├── mod_mult.vhd         ← 12×12-bit multiply mod 3329
│   │   └── mod_add_sub.vhd      ← Conditional mod add/subtract
│   │
│   ├── ntt/                      ← Number Theoretic Transform
│   │   ├── butterfly_ct.vhd     ← Cooley-Tukey butterfly (forward)
│   │   ├── butterfly_gs.vhd     ← Gentleman-Sande butterfly (inverse)
│   │   ├── ntt_engine.vhd       ← 7-level iterative NTT
│   │   ├── ntt_pipeline.vhd     ← 4-port BRAM interface, in-place NTT
│   │   └── twiddle_rom.vhd      ← 128-entry ζ table (from kyber_pkg)
│   │
│   ├── poly/                     ← Polynomial operations
│   │   ├── poly_bram.vhd        ← Simple dual-port BRAM
│   │   ├── poly_bram_4port.vhd  ← 4-port BRAM (2R+2W) for parallel access
│   │   ├── poly_basemul.vhd     ← NTT-domain pointwise multiply
│   │   ├── poly_add.vhd         ← Coefficient-wise addition mod q
│   │   └── poly_sub.vhd         ← Coefficient-wise subtraction mod q
│   │
│   ├── sampling/                 ← Random polynomial generation
│   │   ├── lfsr_prng.vhd        ← 64-bit LFSR (replaces SHAKE-128)
│   │   ├── cbd_sampler.vhd      ← Centered Binomial Distribution, η=2,3
│   │   └── poly_noise_gen.vhd   ← Full polynomial noise generation
│   │
│   ├── codec/                    ← Compression/decompression
│   │   ├── compress.vhd         ← Lossy d-bit compression
│   │   └── decompress.vhd       ← d-bit decompression
│   │
│   └── top/                      ← System controllers
│       ├── kyber_top.vhd         ← Top: 16 BRAMs + all engines + BRAM routing
│       ├── keygen_controller.vhd ← KeyGen FSM
│       └── encaps_controller.vhd ← Encaps FSM
│
├── sim/                          — 9 testbenches
│   ├── tb_barrett_reduce.vhd     ← Verifies Barrett vs reference mod
│   ├── tb_mod_mult.vhd           ← Spot-checks (a×b) mod 3329
│   ├── tb_butterfly.vhd          ← CT and GS butterfly correctness
│   ├── tb_ntt_engine.vhd         ← NTT then INTT = identity
│   ├── tb_ntt_pipeline.vhd       ← Pipeline with BRAM interface
│   ├── tb_bram_write_read.vhd    ← 4-port BRAM r/w test
│   ├── tb_lfsr_quick.vhd         ← LFSR entropy test
│   ├── tb_cbd_sampler.vhd        ← CBD distribution check
│   └── tb_kyber_top.vhd          ← Full system: KeyGen then Encaps
│
├── tables/
│   ├── twiddle_factors.mem       ← 128 forward NTT twiddle factors
│   └── twiddle_factors_inv.mem   ← 128 inverse NTT twiddle factors
│
└── scripts/
    ├── gen_twiddle_rom.py        ← Generates C_ZETAS for kyber_pkg.vhd
    └── verify_ntt.py             ← Python NTT reference (numpy-based)
```

---

## Running the Testbenches

### GHDL (fast, no Vivado needed)

```bash
# Compile all sources in dependency order
ghdl -a --std=08 src/kyber_pkg.vhd
ghdl -a --std=08 src/mod_arith/barrett_reduce.vhd
ghdl -a --std=08 src/mod_arith/mod_mult.vhd
ghdl -a --std=08 src/mod_arith/mod_add_sub.vhd
ghdl -a --std=08 src/ntt/butterfly_ct.vhd
ghdl -a --std=08 src/ntt/butterfly_gs.vhd
ghdl -a --std=08 src/ntt/ntt_engine.vhd
ghdl -a --std=08 src/ntt/twiddle_rom.vhd
ghdl -a --std=08 src/ntt/ntt_pipeline.vhd
ghdl -a --std=08 src/poly/poly_bram.vhd
ghdl -a --std=08 src/poly/poly_bram_4port.vhd
ghdl -a --std=08 src/poly/poly_basemul.vhd
ghdl -a --std=08 src/poly/poly_add.vhd
ghdl -a --std=08 src/poly/poly_sub.vhd
ghdl -a --std=08 src/sampling/lfsr_prng.vhd
ghdl -a --std=08 src/sampling/cbd_sampler.vhd
ghdl -a --std=08 src/sampling/poly_noise_gen.vhd
ghdl -a --std=08 src/codec/compress.vhd
ghdl -a --std=08 src/codec/decompress.vhd
ghdl -a --std=08 src/top/keygen_controller.vhd
ghdl -a --std=08 src/top/encaps_controller.vhd
ghdl -a --std=08 src/top/kyber_top.vhd

# Run individual testbenches
ghdl -a --std=08 sim/tb_barrett_reduce.vhd && ghdl -e --std=08 tb_barrett_reduce
ghdl -r --std=08 tb_barrett_reduce --stop-time=10us

ghdl -a --std=08 sim/tb_ntt_pipeline.vhd && ghdl -e --std=08 tb_ntt_pipeline
ghdl -r --std=08 tb_ntt_pipeline --stop-time=50us

ghdl -a --std=08 sim/tb_kyber_top.vhd && ghdl -e --std=08 tb_kyber_top
ghdl -r --std=08 tb_kyber_top --stop-time=1ms
```

### Python Reference

```bash
# Generate twiddle factors (verify against kyber_pkg.vhd constants)
python3 scripts/gen_twiddle_rom.py

# Verify NTT implementation with numpy reference
python3 scripts/verify_ntt.py
```

---

## NTT Math — Why 3329?

For NTT of length N=256 to work, the modulus q must satisfy:

1. **q is prime** ✓ (3329 is prime)
2. **N | (q-1)** ✓ (256 | 3328, since 3328 = 256 × 13)
3. **Primitive N-th root of unity exists mod q** ✓ (ω = 17, ω^256 ≡ 1 mod 3329)

The twiddle factors are `ζ^k mod 3329` where `ζ = 17` is the primitive 256th root of unity. They are pre-computed in **bit-reversed order** for the Cooley-Tukey radix-2 DIT (Decimation In Time) algorithm.

### Barrett Reduction — Why Not Just Use `mod`?

Hardware division is expensive (~30+ LUTs, multi-cycle). Barrett reduction precomputes `m = ⌊2^24 / q⌋ = 5039` at synthesis time, then at runtime:

```
q = 3329
m = 5039  (precomputed)
For input a (24-bit product):
  q_est = (a × m) >> 24    ← one multiply, one shift
  r = a - q × q_est        ← one multiply, one subtract
  if r >= q: r -= q         ← one conditional subtract
```

Total: 2 multiplications + 2 subtractions, no division. Single-cycle at 100+ MHz.

---

## Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| PRNG | LFSR (not SHAKE-128) | Simplicity for PoC; replace with Keccak for production |
| BRAM count | 16 | k=2 Kyber-512 needs ~8 polys, 16 gives headroom for intermediate values |
| BRAM ports | 4 (2R + 2W) | Enables 2 NTTs + 2 noise gens to work simultaneously |
| Dual NTT | Yes | KeyGen and Encaps have two NTTs that can be parallelized |
| Twiddle storage | In `kyber_pkg` constants | Synthesis-time ROM, no BRAM needed for twiddle table |
| Barrett M width | 13 bits | `floor(2^24 / 3329) = 5039 < 2^13` |

---

## Comparison: Classical vs Post-Quantum

| Algorithm | Type | Key Size | Quantum-safe? | Based On |
|-----------|------|----------|:-------------:|---------|
| RSA-2048 | KEM | 256 bytes | ❌ | Integer factorization |
| X25519 (ECC) | KEM | 32 bytes | ❌ | Discrete logarithm |
| **Kyber-512** | **KEM** | **800 bytes** | **✅** | **MLWE problem** |
| Kyber-768 | KEM | 1184 bytes | ✅ | MLWE (AES-192 level) |
| Kyber-1024 | KEM | 1568 bytes | ✅ | MLWE (AES-256 level) |

The larger key/ciphertext sizes are the price of quantum resistance — hardware acceleration (this FPGA design) makes that overhead practical.

---

## Module Count

| Category | Files |
|----------|-------|
| Package | 1 |
| Modular arithmetic | 3 |
| NTT | 5 |
| Polynomial ops | 5 |
| Sampling | 3 |
| Codec | 2 |
| Controllers + Top | 3 |
| **Source total** | **22** |
| Testbenches | 9 |
| Scripts | 2 |
| Tables | 2 |
| **Grand total** | **35** |
