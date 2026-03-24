library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Testbench for mod_mult
-- Entity ports (from source):
--   clk, a(22:0), b(22:0), valid, result(22:0), done
-- Pipeline: 2 cycles (stage1 = multiply, stage2 = Barrett reduce)
-- Strategy: assert valid='1' for one cycle with inputs, wait 3 rising edges,
--           sample result when done='1'.
entity tb_mod_mult is
end entity tb_mod_mult;

architecture sim of tb_mod_mult is

  constant CLK_PERIOD : time := 10 ns;
  constant Q          : natural := 8380417;

  signal clk    : std_logic := '0';
  signal a_in   : unsigned(22 downto 0) := (others => '0');
  signal b_in   : unsigned(22 downto 0) := (others => '0');
  signal valid  : std_logic := '0';
  signal result : unsigned(22 downto 0);
  signal done   : std_logic;

  -- Apply one multiplication and check the result.
  -- Inputs are presented for one clock (valid='1'). After 2 pipeline stages
  -- done pulses and result is valid.
  procedure check_mult (
    signal   clk_s   : in  std_logic;
    signal   a_s     : out unsigned(22 downto 0);
    signal   b_s     : out unsigned(22 downto 0);
    signal   v_s     : out std_logic;
    signal   res_s   : in  unsigned(22 downto 0);
    signal   done_s  : in  std_logic;
    constant a_val   : in  natural;
    constant b_val   : in  natural;
    constant r_exp   : in  natural;
    constant test_id : in  string
  ) is
  begin
    -- Drive inputs and assert valid for one clock
    a_s <= to_unsigned(a_val, 23);
    b_s <= to_unsigned(b_val, 23);
    v_s <= '1';
    wait until rising_edge(clk_s);  -- stage 1: multiply registered
    v_s <= '0';
    wait until done_s = '1';        -- wait for done pulse (signals settle after delta)
    if to_integer(res_s) = r_exp then
      report "PASS [" & test_id & "] "
           & integer'image(a_val) & " * " & integer'image(b_val)
           & " mod q = " & integer'image(to_integer(res_s))
        severity note;
    else
      report "FAIL [" & test_id & "] "
           & integer'image(a_val) & " * " & integer'image(b_val)
           & "  expected=" & integer'image(r_exp)
           & "  got="      & integer'image(to_integer(res_s))
        severity error;
    end if;
    wait until rising_edge(clk_s);  -- idle gap between tests
  end procedure;

begin

  -- Clock
  clk <= not clk after CLK_PERIOD / 2;

  -- DUT
  dut: entity work.mod_mult
    port map (
      clk    => clk,
      a      => a_in,
      b      => b_in,
      valid  => valid,
      result => result,
      done   => done
    );

  -- Stimulus
  stimulus: process
  begin
    -- Hold inputs idle for a few cycles
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    -- Test 1: 1 * 1 = 1
    check_mult(clk, a_in, b_in, valid, result, done,
               1, 1, 1, "T1: 1*1");

    -- Test 2: 2 * 3 = 6
    check_mult(clk, a_in, b_in, valid, result, done,
               2, 3, 6, "T2: 2*3");

    -- Test 3: (q-1) * 2 mod q
    -- (8380416 * 2) = 16760832 = 2*q - 2, mod q = q-2 = 8380415
    check_mult(clk, a_in, b_in, valid, result, done,
               8380416, 2, 8380415, "T3: (q-1)*2");

    -- Test 4: 100 * 200 = 20000, well within q
    check_mult(clk, a_in, b_in, valid, result, done,
               100, 200, 20000, "T4: 100*200");

    -- Test 5: zeta * 1 = zeta (using C_ZETAS(1) = 4808194)
    check_mult(clk, a_in, b_in, valid, result, done,
               4808194, 1, 4808194, "T5: zeta*1");

    -- Test 6: (q-1) * (q-1) mod q
    -- (q-1)^2 = q^2 - 2q + 1 = q*(q-2) + 1, so mod q = 1
    check_mult(clk, a_in, b_in, valid, result, done,
               8380416, 8380416, 1, "T6: (q-1)^2");

    -- Test 7: 1753 * 1753 mod q (generator squared)
    -- 1753^2 = 3073009, and 3073009 < q, so result = 3073009
    -- Verify: 3073009 is C_ZETAS(64) in dilithium_pkg
    check_mult(clk, a_in, b_in, valid, result, done,
               1753, 1753, 3073009, "T7: g^2=zeta[64]");

    -- Test 8: 0 * anything = 0
    check_mult(clk, a_in, b_in, valid, result, done,
               0, 8380416, 0, "T8: 0*anything");

    wait for 100 ns;
    report "tb_mod_mult: all tests complete" severity note;
    wait;
  end process;

end architecture sim;
