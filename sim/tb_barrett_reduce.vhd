library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Testbench for barrett_reduce
-- Pipeline depth: 1 cycle (registered output)
-- Strategy: apply input, wait 2 rising edges, sample output
entity tb_barrett_reduce is
end entity tb_barrett_reduce;

architecture sim of tb_barrett_reduce is

  constant CLK_PERIOD : time := 10 ns;
  constant Q          : natural := 8380417;

  signal clk   : std_logic := '0';
  signal x_in  : unsigned(45 downto 0) := (others => '0');
  signal r_out : unsigned(22 downto 0);

  -- Helper: apply input, wait 2 cycles, check result
  procedure check_barrett (
    signal   clk_s   : in  std_logic;
    signal   x_s     : out unsigned(45 downto 0);
    signal   r_s     : in  unsigned(22 downto 0);
    constant x_val   : in  unsigned(45 downto 0);
    constant r_exp   : in  natural;
    constant test_id : in  string
  ) is
  begin
    x_s <= x_val;
    wait until rising_edge(clk_s);   -- latch input
    wait until rising_edge(clk_s);   -- output valid after 1 pipeline stage
    if to_integer(r_s) = r_exp then
      report "PASS [" & test_id & "]"
           & " => r=" & integer'image(to_integer(r_s))
        severity note;
    else
      report "FAIL [" & test_id & "]"
           & " expected=" & integer'image(r_exp)
           & " got=" & integer'image(to_integer(r_s))
        severity error;
    end if;
  end procedure;

begin

  -- Clock generation
  clk <= not clk after CLK_PERIOD / 2;

  -- DUT
  dut: entity work.barrett_reduce
    port map (
      clk   => clk,
      x_in  => x_in,
      r_out => r_out
    );

  -- Stimulus
  stimulus: process
  begin
    -- Allow DUT to settle
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    -- Test 1: 0 mod q = 0
    check_barrett(clk, x_in, r_out, to_unsigned(0, 46), 0, "T1: 0");

    -- Test 2: q-1 mod q = q-1 = 8380416
    check_barrett(clk, x_in, r_out, to_unsigned(8380416, 46), 8380416, "T2: q-1");

    -- Test 3: q mod q = 0
    -- Note: Barrett is designed for products up to (q-1)^2; input 'q' itself
    -- is a valid 46-bit input and should reduce to 0.
    check_barrett(clk, x_in, r_out, to_unsigned(8380417, 46), 0, "T3: q->0");

    -- Test 4: 2*(q-1) mod q = 2*8380416 - 8380417 = 8380415
    check_barrett(clk, x_in, r_out, to_unsigned(16760832, 46), 8380415, "T4: 2*(q-1)");

    -- Test 5: 17760834 mod q
    -- 17760834 / 8380417 = 2.xxx, floor=2, 2*8380417 = 16760834
    -- 17760834 - 16760834 = 1000000
    check_barrett(clk, x_in, r_out, to_unsigned(17760834, 46), 1000000, "T5: 17760834");

    -- Test 6: (q-1)^2 mod q = 1  [(q-1) = -1 mod q, (-1)^2 = 1]
    -- (8380416)^2 = 70231372333056 = 0x3FE000400000 (fits in 46 bits)
    check_barrett(clk, x_in, r_out,
      to_unsigned(8380416, 23) * to_unsigned(8380416, 23), 1, "T6: (q-1)^2");

    -- Test 7: small product 100*200 = 20000, which is < q, so mod q = 20000
    check_barrett(clk, x_in, r_out, to_unsigned(20000, 46), 20000, "T7: 100*200=20000");

    -- Test 8: exact multiple 2*q = 16760834, mod q = 0
    check_barrett(clk, x_in, r_out, to_unsigned(16760834, 46), 0, "T8: 2q->0");

    -- Leave a few idle cycles then finish
    wait for 100 ns;
    report "tb_barrett_reduce: all tests complete" severity note;
    wait;
  end process;

end architecture sim;
