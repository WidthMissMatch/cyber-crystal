library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Single-coefficient use_hint: applies hint correction to high bits.
-- Internally instantiates decompose (1-cycle pipeline).
-- hint_in is delayed by 1 cycle to align with decompose output.
--
-- Correction rules:
--   hint=0:              output a1 unchanged
--   hint=1, a0 > 0:      output (a1==43) ? 0 : a1+1
--   hint=1, a0 <= 0:     output (a1==0)  ? 43 : a1-1

entity use_hint is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    a_in      : in  unsigned(22 downto 0);   -- original coefficient [0, q-1]
    hint_in   : in  std_logic;               -- hint bit
    valid_in  : in  std_logic;
    a1_corr   : out unsigned(5 downto 0);    -- corrected high bits [0, 43]
    valid_out : out std_logic
  );
end entity use_hint;

architecture rtl of use_hint is

  -- Decompose pipeline signals
  signal dec_a1_out    : unsigned(5 downto 0);
  signal dec_a0_out    : signed(18 downto 0);
  signal dec_valid_out : std_logic;

  -- Delay register for hint (1 cycle, matching decompose pipeline depth)
  signal hint_r  : std_logic := '0';

  -- Output registers
  signal a1_corr_r   : unsigned(5 downto 0) := (others => '0');
  signal valid_out_r : std_logic := '0';

begin

  -- Instantiate decompose (1-cycle pipeline)
  u_dec : entity work.decompose
    port map (
      clk       => clk,
      rst       => rst,
      a_in      => a_in,
      valid_in  => valid_in,
      a1_out    => dec_a1_out,
      a0_out    => dec_a0_out,
      valid_out => dec_valid_out
    );

  process(clk)
    variable a1_v   : unsigned(5 downto 0);
    variable a0_pos : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        hint_r      <= '0';
        a1_corr_r   <= (others => '0');
        valid_out_r <= '0';
      else
        -- Delay hint by 1 cycle to align with decompose output
        if valid_in = '1' then
          hint_r <= hint_in;
        end if;

        valid_out_r <= dec_valid_out;

        if dec_valid_out = '1' then
          a1_v   := dec_a1_out;
          a0_pos := (dec_a0_out > to_signed(0, 19));

          if hint_r = '0' then
            -- No correction
            a1_corr_r <= a1_v;
          elsif a0_pos then
            -- a0 > 0: increment a1 with wrap at 44 -> 0
            if a1_v = to_unsigned(43, 6) then
              a1_corr_r <= to_unsigned(0, 6);
            else
              a1_corr_r <= a1_v + 1;
            end if;
          else
            -- a0 <= 0: decrement a1 with wrap at 0 -> 43
            if a1_v = to_unsigned(0, 6) then
              a1_corr_r <= to_unsigned(43, 6);
            else
              a1_corr_r <= a1_v - 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  a1_corr   <= a1_corr_r;
  valid_out <= valid_out_r;

end architecture rtl;
