library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Cooley-Tukey butterfly for forward NTT (Dilithium, q=8380417)
-- a' = a + zeta * b  (mod q)
-- b' = a - zeta * b  (mod q)
-- 2-cycle pipeline latency
entity butterfly_ct is
  port (
    clk     : in  std_logic;
    valid_i : in  std_logic;
    a_in    : in  unsigned(22 downto 0);
    b_in    : in  unsigned(22 downto 0);
    zeta    : in  unsigned(22 downto 0);
    a_out   : out unsigned(22 downto 0);
    b_out   : out unsigned(22 downto 0);
    valid_o : out std_logic
  );
end entity butterfly_ct;

architecture rtl of butterfly_ct is
  signal a_d1     : unsigned(22 downto 0) := (others => '0');
  signal product  : unsigned(45 downto 0) := (others => '0');
  signal valid_d1 : std_logic := '0';
  signal valid_d2 : std_logic := '0';
begin

  process(clk)
    variable x_ext  : unsigned(69 downto 0);
    variable quot   : unsigned(23 downto 0);
    variable prod_q : unsigned(46 downto 0);
    variable diff   : unsigned(46 downto 0);
    variable t      : unsigned(22 downto 0);
    variable sum_ab : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      -- Stage 1: multiply zeta * b_in, latch a_in
      product  <= zeta * b_in;
      a_d1     <= a_in;
      valid_d1 <= valid_i;

      -- Stage 2: Barrett reduce, modular add/sub
      x_ext  := product * BARRETT_M;
      quot   := x_ext(69 downto 46);
      prod_q := quot * to_unsigned(DIL_Q, 23);
      diff   := resize(product, 47) - prod_q;

      if diff >= DIL_Q then
        t := resize(diff - DIL_Q, 23);
      else
        t := resize(diff, 23);
      end if;

      -- a' = a + t mod q
      sum_ab := resize(a_d1, 24) + resize(t, 24);
      if sum_ab >= DIL_Q then
        a_out <= resize(sum_ab - DIL_Q, 23);
      else
        a_out <= resize(sum_ab, 23);
      end if;

      -- b' = a - t mod q
      if a_d1 >= t then
        b_out <= resize(a_d1 - t, 23);
      else
        b_out <= resize((resize(a_d1, 24) + to_unsigned(DIL_Q, 24)) - resize(t, 24), 23);
      end if;

      valid_d2 <= valid_d1;
    end if;
  end process;

  valid_o <= valid_d2;

end architecture rtl;
