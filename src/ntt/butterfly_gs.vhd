library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Gentleman-Sande butterfly for inverse NTT (Dilithium, q=8380417)
-- a' = a + b        (mod q)
-- b' = zeta*(b - a) (mod q)
-- 2-cycle pipeline latency
entity butterfly_gs is
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
end entity butterfly_gs;

architecture rtl of butterfly_gs is
  signal sum_r    : unsigned(22 downto 0) := (others => '0');
  signal product  : unsigned(45 downto 0) := (others => '0');
  signal valid_d1 : std_logic := '0';
  signal valid_d2 : std_logic := '0';
begin

  process(clk)
    variable sum_ab : unsigned(23 downto 0);
    variable dif_u  : unsigned(22 downto 0);
    variable x_ext  : unsigned(69 downto 0);
    variable quot   : unsigned(23 downto 0);
    variable prod_q : unsigned(46 downto 0);
    variable diff   : unsigned(46 downto 0);
    variable t      : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      -- Stage 1: a+b mod q, zeta*(b-a)
      sum_ab := resize(a_in, 24) + resize(b_in, 24);
      if sum_ab >= DIL_Q then
        sum_r <= resize(sum_ab - DIL_Q, 23);
      else
        sum_r <= resize(sum_ab, 23);
      end if;

      if b_in >= a_in then
        dif_u := resize(b_in - a_in, 23);
      else
        dif_u := resize((resize(b_in, 24) + to_unsigned(DIL_Q, 24)) - resize(a_in, 24), 23);
      end if;

      product  <= zeta * dif_u;
      valid_d1 <= valid_i;

      -- Stage 2: Barrett reduce product
      x_ext  := product * BARRETT_M;
      quot   := x_ext(69 downto 46);
      prod_q := quot * to_unsigned(DIL_Q, 23);
      diff   := resize(product, 47) - prod_q;

      if diff >= DIL_Q then
        t := resize(diff - DIL_Q, 23);
      else
        t := resize(diff, 23);
      end if;

      a_out <= sum_r;
      b_out <= t;
      valid_d2 <= valid_d1;
    end if;
  end process;

  valid_o <= valid_d2;

end architecture rtl;
