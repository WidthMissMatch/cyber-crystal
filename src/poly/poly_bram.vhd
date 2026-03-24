library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- True dual-port BRAM for one Dilithium polynomial: 256 x 23-bit
-- Uses shared variable for true dual-port access (GHDL -frelaxed compatible)
entity poly_bram is
  port (
    clk    : in  std_logic;
    we_a   : in  std_logic;
    addr_a : in  unsigned(7 downto 0);
    din_a  : in  unsigned(22 downto 0);
    dout_a : out unsigned(22 downto 0);
    we_b   : in  std_logic;
    addr_b : in  unsigned(7 downto 0);
    din_b  : in  unsigned(22 downto 0);
    dout_b : out unsigned(22 downto 0)
  );
end entity poly_bram;

architecture rtl of poly_bram is
  type t_mem is array(0 to DIL_N - 1) of unsigned(COEFF_W - 1 downto 0);
begin

  -- Single-process true dual-port BRAM using variable for conflict-free access.
  -- Variable writes are immediate, so both ports see consistent memory within
  -- the same clock cycle (write-first semantics).
  process(clk)
    variable mem : t_mem := (others => (others => '0'));
  begin
    if rising_edge(clk) then
      if we_a = '1' then
        mem(to_integer(addr_a)) := din_a;
      end if;
      if we_b = '1' then
        mem(to_integer(addr_b)) := din_b;
      end if;
      dout_a <= mem(to_integer(addr_a));
      dout_b <= mem(to_integer(addr_b));
    end if;
  end process;

end architecture rtl;
