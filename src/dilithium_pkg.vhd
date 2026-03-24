library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package dilithium_pkg is

  -- Dilithium-2 (ML-DSA-44) parameters
  constant DIL_N      : positive := 256;
  constant DIL_Q      : positive := 8380417;
  constant DIL_K      : positive := 4;
  constant DIL_L      : positive := 4;
  constant DIL_ETA    : positive := 2;
  constant DIL_TAU    : positive := 39;
  constant DIL_BETA   : positive := 78;   -- tau * eta
  constant DIL_GAMMA1 : positive := 131072;  -- 2^17
  constant DIL_GAMMA2 : positive := 95232;   -- (q-1)/88
  constant DIL_D      : positive := 13;
  constant DIL_OMEGA  : positive := 80;
  constant DIL_ALPHA  : positive := 190464;  -- 2 * gamma2

  -- Bit widths
  constant COEFF_W : positive := 23;  -- ceil(log2(8380417))
  constant MULT_W  : positive := 46;  -- 23 * 2

  -- Barrett reduction: M = ceil(2^46 / q)
  constant BARRETT_M : unsigned(23 downto 0) := to_unsigned(8396808, 24);

  -- N^-1 mod q for INTT scaling. ntt_engine runs 7 butterfly layers
  -- (half_len 128..2), so this is 128^-1 mod 8380417 = 8314945.
  constant N_INV : unsigned(22 downto 0) := to_unsigned(8314945, 23);

  -- Types
  subtype t_coeff is unsigned(COEFF_W - 1 downto 0);
  subtype t_coeff_addr is unsigned(7 downto 0);

  -- Twiddle factor ROM type
  type t_twiddle_rom is array(0 to 127) of t_coeff;

  -- Forward NTT twiddle factors (plain, non-Montgomery)
  -- zetas[k] = 1753^(bitrev8(k)) mod 8380417
  constant C_ZETAS : t_twiddle_rom := (
      0 => to_unsigned(       1, 23),
      1 => to_unsigned( 4808194, 23),
      2 => to_unsigned( 3765607, 23),
      3 => to_unsigned( 3761513, 23),
      4 => to_unsigned( 5178923, 23),
      5 => to_unsigned( 5496691, 23),
      6 => to_unsigned( 5234739, 23),
      7 => to_unsigned( 5178987, 23),
      8 => to_unsigned( 7778734, 23),
      9 => to_unsigned( 3542485, 23),
     10 => to_unsigned( 2682288, 23),
     11 => to_unsigned( 2129892, 23),
     12 => to_unsigned( 3764867, 23),
     13 => to_unsigned( 7375178, 23),
     14 => to_unsigned(  557458, 23),
     15 => to_unsigned( 7159240, 23),
     16 => to_unsigned( 5010068, 23),
     17 => to_unsigned( 4317364, 23),
     18 => to_unsigned( 2663378, 23),
     19 => to_unsigned( 6705802, 23),
     20 => to_unsigned( 4855975, 23),
     21 => to_unsigned( 7946292, 23),
     22 => to_unsigned(  676590, 23),
     23 => to_unsigned( 7044481, 23),
     24 => to_unsigned( 5152541, 23),
     25 => to_unsigned( 1714295, 23),
     26 => to_unsigned( 2453983, 23),
     27 => to_unsigned( 1460718, 23),
     28 => to_unsigned( 7737789, 23),
     29 => to_unsigned( 4795319, 23),
     30 => to_unsigned( 2815639, 23),
     31 => to_unsigned( 2283733, 23),
     32 => to_unsigned( 3602218, 23),
     33 => to_unsigned( 3182878, 23),
     34 => to_unsigned( 2740543, 23),
     35 => to_unsigned( 4793971, 23),
     36 => to_unsigned( 5269599, 23),
     37 => to_unsigned( 2101410, 23),
     38 => to_unsigned( 3704823, 23),
     39 => to_unsigned( 1159875, 23),
     40 => to_unsigned(  394148, 23),
     41 => to_unsigned(  928749, 23),
     42 => to_unsigned( 1095468, 23),
     43 => to_unsigned( 4874037, 23),
     44 => to_unsigned( 2071829, 23),
     45 => to_unsigned( 4361428, 23),
     46 => to_unsigned( 3241972, 23),
     47 => to_unsigned( 2156050, 23),
     48 => to_unsigned( 3415069, 23),
     49 => to_unsigned( 1759347, 23),
     50 => to_unsigned( 7562881, 23),
     51 => to_unsigned( 4805951, 23),
     52 => to_unsigned( 3756790, 23),
     53 => to_unsigned( 6444618, 23),
     54 => to_unsigned( 6663429, 23),
     55 => to_unsigned( 4430364, 23),
     56 => to_unsigned( 5483103, 23),
     57 => to_unsigned( 3192354, 23),
     58 => to_unsigned(  556856, 23),
     59 => to_unsigned( 3870317, 23),
     60 => to_unsigned( 2917338, 23),
     61 => to_unsigned( 1853806, 23),
     62 => to_unsigned( 3345963, 23),
     63 => to_unsigned( 1858416, 23),
     64 => to_unsigned( 3073009, 23),
     65 => to_unsigned( 1277625, 23),
     66 => to_unsigned( 5744944, 23),
     67 => to_unsigned( 3852015, 23),
     68 => to_unsigned( 4183372, 23),
     69 => to_unsigned( 5157610, 23),
     70 => to_unsigned( 5258977, 23),
     71 => to_unsigned( 8106357, 23),
     72 => to_unsigned( 2508980, 23),
     73 => to_unsigned( 2028118, 23),
     74 => to_unsigned( 1937570, 23),
     75 => to_unsigned( 4564692, 23),
     76 => to_unsigned( 2811291, 23),
     77 => to_unsigned( 5396636, 23),
     78 => to_unsigned( 7270901, 23),
     79 => to_unsigned( 4158088, 23),
     80 => to_unsigned( 1528066, 23),
     81 => to_unsigned(  482649, 23),
     82 => to_unsigned( 1148858, 23),
     83 => to_unsigned( 5418153, 23),
     84 => to_unsigned( 7814814, 23),
     85 => to_unsigned(  169688, 23),
     86 => to_unsigned( 2462444, 23),
     87 => to_unsigned( 5046034, 23),
     88 => to_unsigned( 4213992, 23),
     89 => to_unsigned( 4892034, 23),
     90 => to_unsigned( 1987814, 23),
     91 => to_unsigned( 5183169, 23),
     92 => to_unsigned( 1736313, 23),
     93 => to_unsigned(  235407, 23),
     94 => to_unsigned( 5130263, 23),
     95 => to_unsigned( 3258457, 23),
     96 => to_unsigned( 5801164, 23),
     97 => to_unsigned( 1787943, 23),
     98 => to_unsigned( 5989328, 23),
     99 => to_unsigned( 6125690, 23),
    100 => to_unsigned( 3482206, 23),
    101 => to_unsigned( 4197502, 23),
    102 => to_unsigned( 7080401, 23),
    103 => to_unsigned( 6018354, 23),
    104 => to_unsigned( 7062739, 23),
    105 => to_unsigned( 2461387, 23),
    106 => to_unsigned( 3035980, 23),
    107 => to_unsigned(  621164, 23),
    108 => to_unsigned( 3901472, 23),
    109 => to_unsigned( 7153756, 23),
    110 => to_unsigned( 2925816, 23),
    111 => to_unsigned( 3374250, 23),
    112 => to_unsigned( 1356448, 23),
    113 => to_unsigned( 5604662, 23),
    114 => to_unsigned( 2683270, 23),
    115 => to_unsigned( 5601629, 23),
    116 => to_unsigned( 4912752, 23),
    117 => to_unsigned( 2312838, 23),
    118 => to_unsigned( 7727142, 23),
    119 => to_unsigned( 7921254, 23),
    120 => to_unsigned(  348812, 23),
    121 => to_unsigned( 8052569, 23),
    122 => to_unsigned( 1011223, 23),
    123 => to_unsigned( 6026202, 23),
    124 => to_unsigned( 4561790, 23),
    125 => to_unsigned( 6458164, 23),
    126 => to_unsigned( 6143691, 23),
    127 => to_unsigned( 1744507, 23)
  );

  -- Helper functions
  function mod_reduce(val : unsigned) return t_coeff;

end package dilithium_pkg;

package body dilithium_pkg is

  function mod_reduce(val : unsigned) return t_coeff is
    variable v : unsigned(val'length - 1 downto 0);
    variable r : unsigned(COEFF_W - 1 downto 0);
  begin
    v := val;
    if v >= DIL_Q then
      r := resize(v - DIL_Q, COEFF_W);
    else
      r := resize(v, COEFF_W);
    end if;
    return r;
  end function;

end package body dilithium_pkg;
