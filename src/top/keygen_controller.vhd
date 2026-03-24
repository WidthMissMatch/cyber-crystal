library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Key generation controller FSM.
--
-- BRAM allocation (bram_sel):
--   0..15  : A matrix (K*L = 16 uniform polys)
--  16..19  : s1 vector (L = 4 noise polys)
--  20..23  : s2 vector (K = 4 noise polys)
--  24..27  : t1 vector (K = 4 polys, high bits after power2round)
--  28..31  : scratch / t0 (K = 4 polys)
--
-- Pipeline steps (simplified PoC):
--   S_GEN_A   : generate 16 uniform polys for matrix A
--   S_NTT_A   : NTT each of the 16 A polys (forward NTT)
--   S_GEN_S1  : generate 4 noise polys for s1
--   S_NTT_S1  : NTT each of the 4 s1 polys
--   S_GEN_S2  : generate 4 noise polys for s2
--   S_MATVEC  : t = A * NTT(s1) via basemul, accumulate K output polys
--   S_INTT_T  : INTT on scratch polys 28..31
--   S_ADD_S2  : t = t + s2 (poly_add)
--   S_P2R     : power2round on each of K=4 polys
--
-- 2-level FSM: outer_state + S_WAIT_SUB (waiting for submodule done).
entity keygen_controller is
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    start: in  std_logic;
    seed : in  std_logic_vector(63 downto 0);

    -- Shared BRAM interface
    bram_we   : out std_logic;
    bram_addr : out unsigned(7 downto 0);
    bram_din  : out unsigned(22 downto 0);
    bram_dout : in  unsigned(22 downto 0);
    bram_sel  : out unsigned(4 downto 0);   -- selects one of 32 BRAMs

    -- NTT engine
    ntt_start   : out std_logic;
    ntt_inverse : out std_logic;
    ntt_done    : in  std_logic;

    -- Noise polynomial generator
    poly_noise_start : out std_logic;
    poly_noise_seed  : out std_logic_vector(63 downto 0);
    poly_noise_done  : in  std_logic;

    -- Uniform polynomial generator
    poly_uniform_start : out std_logic;
    poly_uniform_seed  : out std_logic_vector(63 downto 0);
    poly_uniform_done  : in  std_logic;

    -- Polynomial addition
    poly_add_start : out std_logic;
    poly_add_done  : in  std_logic;

    -- Polynomial base multiplication
    poly_basemul_start : out std_logic;
    poly_basemul_done  : in  std_logic;

    -- Power2Round decomposition
    power2round_start : out std_logic;
    power2round_done  : in  std_logic;

    done : out std_logic;
    busy : out std_logic
  );
end entity keygen_controller;

architecture rtl of keygen_controller is

  -- Outer FSM states (one per pipeline step plus wait state)
  type t_outer is (
    S_IDLE,
    S_GEN_A,
    S_NTT_A,
    S_GEN_S1,
    S_NTT_S1,
    S_GEN_S2,
    S_MATVEC,
    S_INTT_T,
    S_ADD_S2,
    S_P2R,
    S_WAIT_SUB,
    S_DONE
  );

  signal outer_state : t_outer := S_IDLE;
  -- State to return to after S_WAIT_SUB completes one poly iteration
  signal return_state : t_outer := S_IDLE;

  -- Polynomial index counter (supports 0..15 for A matrix, 0..3 for vectors)
  signal poly_idx : unsigned(4 downto 0) := (others => '0');

  -- Maximum index for current loop (15 for A-matrix loops, 3 for vectors)
  signal poly_max : unsigned(4 downto 0) := (others => '0');

  -- BRAM base offset for current loop
  signal bram_base : unsigned(4 downto 0) := (others => '0');

begin

  -- BRAM address/we are driven per-step; default to safe idle values
  bram_we   <= '0';
  bram_addr <= (others => '0');
  bram_din  <= (others => '0');

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        outer_state        <= S_IDLE;
        return_state       <= S_IDLE;
        poly_idx           <= (others => '0');
        poly_max           <= (others => '0');
        bram_base          <= (others => '0');
        bram_sel           <= (others => '0');
        done               <= '0';
        busy               <= '0';
        ntt_start          <= '0';
        ntt_inverse        <= '0';
        poly_noise_start   <= '0';
        poly_noise_seed    <= (others => '0');
        poly_uniform_start <= '0';
        poly_uniform_seed  <= (others => '0');
        poly_add_start     <= '0';
        poly_basemul_start <= '0';
        power2round_start  <= '0';
      else
        -- Default pulse de-assertion
        done               <= '0';
        ntt_start          <= '0';
        poly_noise_start   <= '0';
        poly_uniform_start <= '0';
        poly_add_start     <= '0';
        poly_basemul_start <= '0';
        power2round_start  <= '0';

        case outer_state is

          -- -------------------------------------------------------
          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              busy        <= '1';
              poly_idx    <= (others => '0');
              poly_max    <= to_unsigned(15, 5);   -- 0..15 (16 polys)
              bram_base   <= (others => '0');       -- BRAMs 0..15
              outer_state <= S_GEN_A;
            end if;

          -- -------------------------------------------------------
          -- Generate 16 uniform polynomials for matrix A (BRAMs 0..15)
          when S_GEN_A =>
            bram_sel           <= bram_base + poly_idx;
            poly_uniform_seed  <= std_logic_vector(
                                    unsigned(seed) xor resize(poly_idx, 64));
            poly_uniform_start <= '1';
            return_state       <= S_GEN_A;
            outer_state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- NTT each of the 16 A polynomials (BRAMs 0..15)
          when S_NTT_A =>
            bram_sel    <= bram_base + poly_idx;   -- base=0
            ntt_inverse <= '0';
            ntt_start   <= '1';
            return_state <= S_NTT_A;
            outer_state  <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Generate 4 noise polynomials for s1 (BRAMs 16..19)
          when S_GEN_S1 =>
            bram_sel          <= bram_base + poly_idx;   -- base=16
            poly_noise_seed   <= std_logic_vector(
                                   unsigned(seed) xor resize(poly_idx, 64));
            poly_noise_start  <= '1';
            return_state      <= S_GEN_S1;
            outer_state       <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- NTT each of the 4 s1 polynomials (BRAMs 16..19)
          when S_NTT_S1 =>
            bram_sel     <= bram_base + poly_idx;   -- base=16
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_NTT_S1;
            outer_state  <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Generate 4 noise polynomials for s2 (BRAMs 20..23)
          when S_GEN_S2 =>
            bram_sel         <= bram_base + poly_idx;   -- base=20
            poly_noise_seed  <= std_logic_vector(
                                  unsigned(seed) xor
                                  (resize(poly_idx, 64) or x"0000000000000010"));
            poly_noise_start <= '1';
            return_state     <= S_GEN_S2;
            outer_state      <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Matrix-vector product: t = A * NTT(s1)
          -- For each of K=4 output polys accumulate L=4 basemul results.
          -- (Simplified: one basemul start per poly_idx, controller
          --  assumes basemul engine reads A and s1 via bram_sel protocol.)
          when S_MATVEC =>
            bram_sel           <= to_unsigned(28, 5) + poly_idx; -- scratch 28..31
            poly_basemul_start <= '1';
            return_state       <= S_MATVEC;
            outer_state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- INTT on scratch polys 28..31 → produces t in time domain
          when S_INTT_T =>
            bram_sel     <= to_unsigned(28, 5) + poly_idx;
            ntt_inverse  <= '1';
            ntt_start    <= '1';
            return_state <= S_INTT_T;
            outer_state  <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- t = t + s2 : poly_add for each of K=4 polys
          -- (controller signals which polys via bram_sel;
          --  poly_add engine reads src_a=scratch 28+i, src_b=s2 20+i,
          --  writes result back to scratch 28+i)
          when S_ADD_S2 =>
            bram_sel       <= to_unsigned(28, 5) + poly_idx;
            poly_add_start <= '1';
            return_state   <= S_ADD_S2;
            outer_state    <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- power2round: scratch 28+i → t1 (24+i) and t0 (28+i)
          when S_P2R =>
            bram_sel          <= to_unsigned(28, 5) + poly_idx;
            power2round_start <= '1';
            return_state      <= S_P2R;
            outer_state       <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Wait for the active sub-module to finish, then
          -- advance poly_idx or move to the next outer state.
          when S_WAIT_SUB =>
            if (ntt_done          = '1' or
                poly_uniform_done = '1' or
                poly_noise_done   = '1' or
                poly_add_done     = '1' or
                poly_basemul_done = '1' or
                power2round_done  = '1') then

              if poly_idx = poly_max then
                -- Loop complete: advance to next pipeline stage
                poly_idx <= (others => '0');

                case return_state is
                  when S_GEN_A =>
                    -- After generating A, NTT A
                    poly_max    <= to_unsigned(15, 5);
                    bram_base   <= (others => '0');
                    outer_state <= S_NTT_A;

                  when S_NTT_A =>
                    -- After NTT(A), generate s1
                    poly_max    <= to_unsigned(3, 5);
                    bram_base   <= to_unsigned(16, 5);
                    outer_state <= S_GEN_S1;

                  when S_GEN_S1 =>
                    -- After generating s1, NTT s1
                    poly_max    <= to_unsigned(3, 5);
                    bram_base   <= to_unsigned(16, 5);
                    outer_state <= S_NTT_S1;

                  when S_NTT_S1 =>
                    -- After NTT(s1), generate s2
                    poly_max    <= to_unsigned(3, 5);
                    bram_base   <= to_unsigned(20, 5);
                    outer_state <= S_GEN_S2;

                  when S_GEN_S2 =>
                    -- After generating s2, do matvec
                    poly_max    <= to_unsigned(3, 5);
                    bram_base   <= to_unsigned(28, 5);
                    outer_state <= S_MATVEC;

                  when S_MATVEC =>
                    -- After matvec, INTT the t scratch polys
                    poly_max    <= to_unsigned(3, 5);
                    outer_state <= S_INTT_T;

                  when S_INTT_T =>
                    -- After INTT(t), add s2
                    poly_max    <= to_unsigned(3, 5);
                    outer_state <= S_ADD_S2;

                  when S_ADD_S2 =>
                    -- After add_s2, power2round
                    poly_max    <= to_unsigned(3, 5);
                    outer_state <= S_P2R;

                  when S_P2R =>
                    -- Key generation complete
                    outer_state <= S_DONE;

                  when others =>
                    outer_state <= S_DONE;
                end case;

              else
                -- More polys to process: increment and loop
                poly_idx    <= poly_idx + 1;
                outer_state <= return_state;
              end if;
            end if;

          -- -------------------------------------------------------
          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            outer_state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
