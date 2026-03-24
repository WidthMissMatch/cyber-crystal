library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Coefficient-wise polynomial addition mod q = 8380417
-- result[i] = (a[i] + b[i]) mod q, for i = 0..255
entity poly_add is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    src_a_addr : out unsigned(7 downto 0);
    src_a_data : in  unsigned(22 downto 0);
    src_b_addr : out unsigned(7 downto 0);
    src_b_data : in  unsigned(22 downto 0);
    dst_we     : out std_logic;
    dst_addr   : out unsigned(7 downto 0);
    dst_data   : out unsigned(22 downto 0);
    done       : out std_logic;
    busy       : out std_logic
  );
end entity poly_add;

architecture rtl of poly_add is
  type t_state is (S_IDLE, S_READ, S_WAIT, S_ADD, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');
begin

  process(clk)
    variable sum : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state  <= S_IDLE;
        done   <= '0';
        busy   <= '0';
        dst_we <= '0';
      else
        dst_we <= '0';

        case state is
          when S_IDLE =>
            done <= '0';
            busy <= '0';
            if start = '1' then
              idx   <= (others => '0');
              busy  <= '1';
              state <= S_READ;
            end if;

          when S_READ =>
            src_a_addr <= idx;
            src_b_addr <= idx;
            state      <= S_WAIT;

          when S_WAIT =>
            state <= S_ADD;

          when S_ADD =>
            sum := resize(src_a_data, 24) + resize(src_b_data, 24);
            if sum >= DIL_Q then
              dst_data <= resize(sum - DIL_Q, 23);
            else
              dst_data <= resize(sum, 23);
            end if;
            dst_addr <= idx;
            dst_we   <= '1';

            if idx = 255 then
              state <= S_DONE;
            else
              idx   <= idx + 1;
              state <= S_READ;
            end if;

          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
