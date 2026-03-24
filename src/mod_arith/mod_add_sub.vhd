library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Modular add/subtract mod 8380417 (23-bit coefficients)
-- is_sub = '0' => result = (a + b) mod q
-- is_sub = '1' => result = (a - b) mod q
-- 1-cycle registered output
entity mod_add_sub is
  port (
    clk    : in  std_logic;
    a      : in  unsigned(22 downto 0);
    b      : in  unsigned(22 downto 0);
    is_sub : in  std_logic;
    result : out unsigned(22 downto 0)
  );
end entity mod_add_sub;

architecture rtl of mod_add_sub is
begin

  process(clk)
    variable sum : unsigned(23 downto 0);
    variable r   : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      if is_sub = '0' then
        sum := resize(a, 24) + resize(b, 24);
        if sum >= DIL_Q then
          r := resize(sum - DIL_Q, 23);
        else
          r := resize(sum, 23);
        end if;
      else
        if a >= b then
          sum := resize(a, 24) - resize(b, 24);
          if sum >= DIL_Q then
            r := resize(sum - DIL_Q, 23);
          else
            r := resize(sum, 23);
          end if;
        else
          r := resize((resize(a, 24) + to_unsigned(DIL_Q, 24)) - resize(b, 24), 23);
        end if;
      end if;
      result <= r;
    end if;
  end process;

end architecture rtl;
