library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Centered Binomial Distribution sampler for Dilithium
-- For G_ETA=2: reads 4 bits, outputs (a0+a1)-(b0+b1) in [-2, +2]
-- Negative values as DIL_Q + diff (mod q, 23-bit)
entity cbd_sampler is
  generic (
    G_ETA : positive := 2
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    rnd_bits : in  std_logic_vector(2*G_ETA - 1 downto 0);
    rnd_valid: in  std_logic;
    coeff    : out unsigned(22 downto 0);
    coeff_v  : out std_logic
  );
end entity cbd_sampler;

architecture rtl of cbd_sampler is
begin
  process(clk)
    variable sum_a : unsigned(2 downto 0);
    variable sum_b : unsigned(2 downto 0);
    variable diff  : signed(3 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        coeff_v <= '0';
      elsif rnd_valid = '1' then
        sum_a := (others => '0');
        sum_b := (others => '0');
        for i in 0 to G_ETA - 1 loop
          sum_a := sum_a + unsigned'("00" & rnd_bits(i));
          sum_b := sum_b + unsigned'("00" & rnd_bits(G_ETA + i));
        end loop;
        diff := signed(resize(sum_a, 4)) - signed(resize(sum_b, 4));
        if diff < 0 then
          coeff <= to_unsigned(DIL_Q + to_integer(diff), 23);
        else
          coeff <= to_unsigned(to_integer(diff), 23);
        end if;
        coeff_v <= '1';
      else
        coeff_v <= '0';
      end if;
    end if;
  end process;
end architecture rtl;
