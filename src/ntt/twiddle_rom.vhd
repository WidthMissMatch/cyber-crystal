library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Twiddle factor ROM for Dilithium NTT/INTT
-- 128 entries, 23-bit wide; reads from C_ZETAS package constant
entity twiddle_rom is
  port (
    clk  : in  std_logic;
    addr : in  unsigned(6 downto 0);
    data : out unsigned(22 downto 0)
  );
end entity twiddle_rom;

architecture rtl of twiddle_rom is
begin
  process(clk)
  begin
    if rising_edge(clk) then
      data <= C_ZETAS(to_integer(addr));
    end if;
  end process;
end architecture rtl;
