library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Barrett reduction for q = 8380417 (23-bit modulus)
-- Reduces a 46-bit value (product of two 23-bit values) mod q
-- Algorithm: quot = (x * M) >> 46, r = x - quot*q, conditional subtract
-- 1-cycle registered output
entity barrett_reduce is
  port (
    clk   : in  std_logic;
    x_in  : in  unsigned(45 downto 0);
    r_out : out unsigned(22 downto 0)
  );
end entity barrett_reduce;

architecture rtl of barrett_reduce is
  signal r_reg : unsigned(22 downto 0);
begin

  process(clk)
    variable x_ext  : unsigned(69 downto 0);  -- 46 + 24 = 70 bits
    variable quot   : unsigned(23 downto 0);
    variable prod_q : unsigned(46 downto 0);
    variable diff   : unsigned(46 downto 0);
    variable result : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      x_ext  := x_in * BARRETT_M;
      quot   := x_ext(69 downto 46);
      prod_q := quot * to_unsigned(DIL_Q, 23);
      diff   := resize(x_in, 47) - prod_q;
      if diff >= DIL_Q then
        result := resize(diff - DIL_Q, 23);
      else
        result := resize(diff, 23);
      end if;
      r_reg <= result;
    end if;
  end process;

  r_out <= r_reg;

end architecture rtl;
