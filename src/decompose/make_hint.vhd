library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Single-coefficient make_hint: computes 1-bit hint from (a0, a1).
-- hint = 1 iff |a0| > GAMMA2  OR  (a0 == -GAMMA2 AND a1 != 0)
-- Equivalently:
--   a0 >  GAMMA2                    -> hint = 1
--   a0 < -GAMMA2                    -> hint = 1
--   a0 == -GAMMA2 AND a1 /= 0       -> hint = 1
-- 1-cycle registered pipeline.

entity make_hint is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    a0_in     : in  signed(18 downto 0);     -- centred low bits (range ~[-95232, 95232])
    a1_in     : in  unsigned(5 downto 0);    -- high bits [0, 43]
    valid_in  : in  std_logic;
    hint_out  : out std_logic;
    valid_out : out std_logic
  );
end entity make_hint;

architecture rtl of make_hint is

  -- DIL_GAMMA2 = 95232. 19-bit signed max = 262143, so 95232 fits.
  constant G2_POS : signed(18 downto 0) := to_signed( DIL_GAMMA2, 19);
  constant G2_NEG : signed(18 downto 0) := to_signed(-DIL_GAMMA2, 19);

  signal hint_r  : std_logic := '0';
  signal valid_r : std_logic := '0';

begin

  process(clk)
    variable cond_pos   : boolean;
    variable cond_neg   : boolean;
    variable cond_eq    : boolean;
    variable hint_v     : std_logic;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        hint_r  <= '0';
        valid_r <= '0';
      else
        valid_r <= valid_in;

        if valid_in = '1' then
          cond_pos := (a0_in >  G2_POS);
          cond_neg := (a0_in <  G2_NEG);
          cond_eq  := (a0_in =  G2_NEG) and (a1_in /= 0);

          if cond_pos or cond_neg or cond_eq then
            hint_v := '1';
          else
            hint_v := '0';
          end if;
          hint_r <= hint_v;
        end if;
      end if;
    end if;
  end process;

  hint_out  <= hint_r;
  valid_out <= valid_r;

end architecture rtl;
