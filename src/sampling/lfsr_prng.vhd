library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- 64-bit Galois LFSR pseudo-random number generator
-- PoC replacement for SHAKE-256 (NOT cryptographically secure)
-- Polynomial: x^64 + x^63 + x^61 + x^60 + 1
-- Outputs 8 random bits per cycle
entity lfsr_prng is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    seed     : in  std_logic_vector(63 downto 0);
    load     : in  std_logic;
    enable   : in  std_logic;
    rnd_out  : out std_logic_vector(7 downto 0);
    valid    : out std_logic
  );
end entity lfsr_prng;

architecture rtl of lfsr_prng is
  signal lfsr : std_logic_vector(63 downto 0) := x"DEADBEEFCAFE1234";
begin
  process(clk)
    variable fb : std_logic;
    variable s  : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        lfsr  <= x"DEADBEEFCAFE1234";
        valid <= '0';
      elsif load = '1' then
        lfsr  <= seed;
        valid <= '0';
      elsif enable = '1' then
        s := lfsr;
        for i in 0 to 7 loop
          fb := s(63);
          s  := s(62 downto 0) & '0';
          if fb = '1' then
            s := s xor x"D800000000000000";
          end if;
        end loop;
        lfsr    <= s;
        rnd_out <= s(63 downto 56);
        valid   <= '1';
      else
        valid <= '0';
      end if;
    end if;
  end process;
end architecture rtl;
