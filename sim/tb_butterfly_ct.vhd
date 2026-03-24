library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Testbench for butterfly_ct (Cooley-Tukey butterfly)
-- Entity ports (from source):
--   clk, valid_i, a_in(22:0), b_in(22:0), zeta(22:0),
--   a_out(22:0), b_out(22:0), valid_o
-- Pipeline: 2 cycles (stage1 = zeta*b, stage2 = Barrett + add/sub)
--
-- CT butterfly:  t = zeta * b  mod q
--                a' = a + t   mod q
--                b' = a - t   mod q
entity tb_butterfly_ct is
end entity tb_butterfly_ct;

architecture sim of tb_butterfly_ct is

  constant CLK_PERIOD : time := 10 ns;
  constant Q          : natural := 8380417;

  signal clk     : std_logic := '0';
  signal valid_i : std_logic := '0';
  signal a_in    : unsigned(22 downto 0) := (others => '0');
  signal b_in    : unsigned(22 downto 0) := (others => '0');
  signal zeta_in : unsigned(22 downto 0) := (others => '0');
  signal a_out   : unsigned(22 downto 0);
  signal b_out   : unsigned(22 downto 0);
  signal valid_o : std_logic;

  -- Apply one butterfly, wait 2 pipeline stages, check outputs.
  procedure check_ct (
    signal   clk_s    : in  std_logic;
    signal   vi_s     : out std_logic;
    signal   a_s      : out unsigned(22 downto 0);
    signal   b_s      : out unsigned(22 downto 0);
    signal   z_s      : out unsigned(22 downto 0);
    signal   ao_s     : in  unsigned(22 downto 0);
    signal   bo_s     : in  unsigned(22 downto 0);
    constant a_val    : in  natural;
    constant b_val    : in  natural;
    constant z_val    : in  natural;
    constant a_exp    : in  natural;
    constant b_exp    : in  natural;
    constant test_id  : in  string
  ) is
  begin
    a_s  <= to_unsigned(a_val, 23);
    b_s  <= to_unsigned(b_val, 23);
    z_s  <= to_unsigned(z_val, 23);
    vi_s <= '1';
    wait until rising_edge(clk_s);  -- stage 1: zeta*b registered
    vi_s <= '0';
    wait until rising_edge(clk_s);  -- stage 2: outputs computed
    wait until rising_edge(clk_s);  -- extra wait: signals settle in DUT registers
    if to_integer(ao_s) = a_exp and to_integer(bo_s) = b_exp then
      report "PASS [" & test_id & "]"
           & "  a=" & integer'image(a_val)
           & "  b=" & integer'image(b_val)
           & "  z=" & integer'image(z_val)
           & "  => a'=" & integer'image(to_integer(ao_s))
           & "  b'=" & integer'image(to_integer(bo_s))
        severity note;
    else
      if to_integer(ao_s) /= a_exp then
        report "FAIL [" & test_id & "] a' mismatch"
             & "  expected=" & integer'image(a_exp)
             & "  got="      & integer'image(to_integer(ao_s))
          severity error;
      end if;
      if to_integer(bo_s) /= b_exp then
        report "FAIL [" & test_id & "] b' mismatch"
             & "  expected=" & integer'image(b_exp)
             & "  got="      & integer'image(to_integer(bo_s))
          severity error;
      end if;
    end if;
    -- One idle gap between tests
    wait until rising_edge(clk_s);
  end procedure;

begin

  -- Clock
  clk <= not clk after CLK_PERIOD / 2;

  -- DUT
  dut: entity work.butterfly_ct
    port map (
      clk     => clk,
      valid_i => valid_i,
      a_in    => a_in,
      b_in    => b_in,
      zeta    => zeta_in,
      a_out   => a_out,
      b_out   => b_out,
      valid_o => valid_o
    );

  -- Stimulus
  stimulus: process
  begin
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    -- ------------------------------------------------------------------
    -- Test 1: a=1, b=1, zeta=1
    -- t = 1*1 mod q = 1
    -- a' = 1 + 1 = 2
    -- b' = 1 - 1 = 0
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             1, 1, 1,   2, 0,   "T1: a=1,b=1,z=1");

    -- ------------------------------------------------------------------
    -- Test 2: a=0, b=1, zeta=1753 (generator)
    -- t = 1753 * 1 mod q = 1753
    -- a' = 0 + 1753 = 1753
    -- b' = 0 - 1753 mod q = q - 1753 = 8378664
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             0, 1, 1753,   1753, 8378664,   "T2: a=0,b=1,z=1753");

    -- ------------------------------------------------------------------
    -- Test 3: a=8380416 (q-1), b=1, zeta=1
    -- t = 1
    -- a' = (q-1) + 1 = q = 0 (mod q)
    -- b' = (q-1) - 1 = q - 2 = 8380415
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             8380416, 1, 1,   0, 8380415,   "T3: a=q-1,b=1,z=1");

    -- ------------------------------------------------------------------
    -- Test 4: a=4190208, b=4190208, zeta=1
    -- t = 4190208
    -- a' = 4190208 + 4190208 = 8380416 = q-1 (no overflow since 8380416 < q)
    -- b' = 4190208 - 4190208 = 0
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             4190208, 4190208, 1,   8380416, 0,   "T4: midpoint butterfly");

    -- ------------------------------------------------------------------
    -- Test 5: zeta = C_ZETAS(0) = 1, identity-like
    -- a=100, b=200, zeta=1
    -- t = 200
    -- a' = 300
    -- b' = 100 - 200 = -100 mod q = q - 100 = 8380317
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             100, 200, 1,   300, 8380317,   "T5: a=100,b=200,z=1");

    -- ------------------------------------------------------------------
    -- Test 6: a=0, b=4808194, zeta=1753
    -- t = 1753 * 4808194 mod q
    -- 1753 * 4808194 = 8428764082; 1005*8380417=8422319085
    -- 8428764082 - 8422319085 = 6444997
    -- a' = 0 + 6444997 = 6444997
    -- b' = 0 - 6444997 mod q = 8380417 - 6444997 = 1935420
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             0, 4808194, 1753,   6444997, 1935420,   "T6: a=0,b=zeta1,z=g");

    -- ------------------------------------------------------------------
    -- Test 7: a=0, b=0, zeta=anything — result a'=0, b'=0
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             0, 0, 4808194,   0, 0,   "T7: both zero");

    -- ------------------------------------------------------------------
    -- Test 8: a=q-1, b=q-1, zeta=q-1
    -- t = (q-1)^2 mod q = 1  (since (q-1)=-1 in Z_q, (-1)^2=1)
    -- a' = (q-1) + 1 = q = 0
    -- b' = (q-1) - 1 = q-2 = 8380415
    -- ------------------------------------------------------------------
    check_ct(clk, valid_i, a_in, b_in, zeta_in, a_out, b_out,
             8380416, 8380416, 8380416,   0, 8380415,   "T8: all q-1");

    wait for 100 ns;
    report "tb_butterfly_ct: all tests complete" severity note;
    wait;
  end process;

end architecture sim;
