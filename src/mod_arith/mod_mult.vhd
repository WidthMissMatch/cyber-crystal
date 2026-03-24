library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Modular multiply mod 8380417 (23-bit coefficients)
-- 2-cycle pipeline: cycle 1 = multiply, cycle 2 = Barrett reduce
entity mod_mult is
  port (
    clk    : in  std_logic;
    a      : in  unsigned(22 downto 0);
    b      : in  unsigned(22 downto 0);
    valid  : in  std_logic;
    result : out unsigned(22 downto 0);
    done   : out std_logic
  );
end entity mod_mult;

architecture rtl of mod_mult is
  signal product : unsigned(45 downto 0) := (others => '0');
  signal valid_d : std_logic             := '0';
  signal done_r  : std_logic             := '0';
  signal reduced : unsigned(22 downto 0) := (others => '0');
begin

  process(clk)
    variable x_ext  : unsigned(69 downto 0);
    variable quot   : unsigned(23 downto 0);
    variable prod_q : unsigned(46 downto 0);
    variable diff   : unsigned(46 downto 0);
    variable r      : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      -- Stage 1: multiply
      product <= a * b;
      valid_d <= valid;

      -- Stage 2: Barrett reduce
      x_ext  := product * BARRETT_M;
      quot   := x_ext(69 downto 46);
      prod_q := quot * to_unsigned(DIL_Q, 23);
      diff   := resize(product, 47) - prod_q;
      if diff >= DIL_Q then
        r := resize(diff - DIL_Q, 23);
      else
        r := resize(diff, 23);
      end if;

      reduced <= r;
      done_r  <= valid_d;
    end if;
  end process;

  result <= reduced;
  done   <= done_r;

end architecture rtl;
