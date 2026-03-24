library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Testbench for decompose module (actual entity interface)
-- decompose entity:
--   clk, rst       : std_logic
--   a_in           : in  unsigned(22 downto 0)
--   valid_in       : in  std_logic
--   a1_out         : out unsigned(5 downto 0)   [0, 43]
--   a0_out         : out signed(18 downto 0)    centred in (-gamma2, gamma2]
--   valid_out      : out std_logic
--
-- Pipeline: 1 cycle (valid_in -> compute -> register -> valid_out)
entity tb_decompose is
end entity tb_decompose;

architecture sim of tb_decompose is

  constant CLK_PERIOD : time    := 10 ns;
  constant Q          : integer := 8380417;
  constant GAMMA2     : integer := 95232;    -- (q-1)/88
  constant TWO_GAMMA2 : integer := 190464;   -- 2*gamma2

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal a_in      : unsigned(22 downto 0) := (others => '0');
  signal valid_in  : std_logic := '0';
  signal a1_out    : unsigned(5 downto 0);
  signal a0_out    : signed(18 downto 0);
  signal valid_out : std_logic;

  -- Apply one decompose and check results.
  -- valid_in pulses for 1 cycle; valid_out fires 1 cycle later.
  procedure check_decompose (
    signal   clk_s    : in  std_logic;
    signal   vin_s    : out std_logic;
    signal   ain_s    : out unsigned(22 downto 0);
    signal   a1_s     : in  unsigned(5 downto 0);
    signal   a0_s     : in  signed(18 downto 0);
    signal   vout_s   : in  std_logic;
    constant a_val    : in  integer;
    constant a1_exp   : in  integer;
    constant a0_exp   : in  integer;
    constant test_id  : in  string
  ) is
    variable a1_got : integer;
    variable a0_got : integer;
    variable rt     : integer;
    variable pass   : boolean;
  begin
    ain_s <= to_unsigned(a_val, 23);
    vin_s <= '1';
    wait until rising_edge(clk_s);   -- present inputs
    vin_s <= '0';
    wait until vout_s = '1';         -- wait for pipeline output
    a1_got := to_integer(a1_s);
    a0_got := to_integer(a0_s);
    pass   := true;
    if a1_got /= a1_exp then
      report "FAIL [" & test_id & "] a1: expected=" & integer'image(a1_exp)
           & " got=" & integer'image(a1_got) severity error;
      pass := false;
    end if;
    if a0_got /= a0_exp then
      report "FAIL [" & test_id & "] a0: expected=" & integer'image(a0_exp)
           & " got=" & integer'image(a0_got) severity error;
      pass := false;
    end if;
    -- Round-trip: a1*2*GAMMA2 + a0 = a (mod q)
    rt := (a1_got * TWO_GAMMA2 + a0_got) mod Q;
    if rt < 0 then rt := rt + Q; end if;
    if rt /= (a_val mod Q) then
      report "FAIL [" & test_id & "] round-trip: got " & integer'image(rt)
           & " expected " & integer'image(a_val mod Q) severity error;
      pass := false;
    end if;
    if pass then
      report "PASS [" & test_id & "] a=" & integer'image(a_val)
           & " => a1=" & integer'image(a1_got)
           & " a0=" & integer'image(a0_got) severity note;
    end if;
    wait until rising_edge(clk_s);   -- idle gap
  end procedure;

begin

  clk <= not clk after CLK_PERIOD / 2;

  dut: entity work.decompose
    port map (
      clk       => clk,
      rst       => rst,
      a_in      => a_in,
      valid_in  => valid_in,
      a1_out    => a1_out,
      a0_out    => a0_out,
      valid_out => valid_out
    );

  stimulus: process
  begin
    rst <= '1';
    wait for 4 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- T1: a=0 => a1=0, a0=0
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    0,  0, 0,  "T1: a=0");

    -- T2: a=190464 (2*gamma2) => a1=1, a0=0
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    190464,  1, 0,  "T2: a=2*gamma2");

    -- T3: a=95232 (gamma2) => a1=0, a0=95232
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    95232,  0, 95232,  "T3: a=gamma2");

    -- T4: a=285696 (3*gamma2) => a1=1, a0=95232
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    285696,  1, 95232,  "T4: a=3*gamma2");

    -- T5: a=190463 (2*gamma2-1) => a1=1, a0=-1
    -- floor-approx gives a1=1, a0=190463-190464=-1
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    190463,  1, -1,  "T5: a=2g2-1");

    -- T6: a=q-1=8380416 => a1=0, a0=-1
    -- 44*190464=8380416 -> a1 clamped to 0, a0=8380416 -> centred: 8380416-q=-1
    check_decompose(clk, valid_in, a_in, a1_out, a0_out, valid_out,
                    8380416,  0, -1,  "T6: a=q-1");

    wait for 100 ns;
    report "tb_decompose: all tests complete" severity note;
    wait;
  end process;

end architecture sim;
