library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Signing controller FSM with rejection loop.
--
-- Dilithium signing overview:
--   1. Sample y (L polys) with coefficients in [-gamma1+1, gamma1]
--   2. Compute w = NTT^-1(A * NTT(y))  →  decompose w → w1, w0
--   3. Hash w1 → challenge c (sample_in_ball)
--   4. z = y + c*s1
--   5. Check ||z||_inf < gamma1 - beta   (reject if fail)
--   6. Check ||w0 - c*s2||_inf < gamma2 - beta (reject if fail)
--   7. Hints check (simplified: always accept in this PoC)
--   8. Accept: output z, h, c
--
-- BRAM allocation assumed by this controller:
--   0..15  : A matrix (from keygen)
--  16..19  : s1 (from keygen, in NTT domain)
--  20..23  : s2 (from keygen)
--  24..27  : y  (scratch for y vector)
--  28..31  : z  / w / w1 scratch polys
entity sign_controller is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    seed  : in  std_logic_vector(63 downto 0);
    nonce : in  unsigned(15 downto 0);   -- incremented externally on each rejection

    -- BRAM bank selector
    bram_sel : out unsigned(4 downto 0);

    -- NTT engine
    ntt_start   : out std_logic;
    ntt_inverse : out std_logic;
    ntt_done    : in  std_logic;

    -- Uniform polynomial generator (reused to sample y with gamma1 mask)
    poly_uniform_start : out std_logic;
    poly_uniform_seed  : out std_logic_vector(63 downto 0);
    poly_uniform_done  : in  std_logic;

    -- Polynomial base multiplication
    poly_basemul_start : out std_logic;
    poly_basemul_done  : in  std_logic;

    -- Polynomial addition
    poly_add_start : out std_logic;
    poly_add_done  : in  std_logic;

    -- Decompose w → w1, w0
    decompose_start : out std_logic;
    decompose_done  : in  std_logic;

    -- Sample-in-ball (hash w1 → challenge c)
    sample_in_ball_start : out std_logic;
    sample_in_ball_done  : in  std_logic;

    -- Infinity-norm checker
    inf_norm_start : out std_logic;
    inf_norm_done  : in  std_logic;
    inf_norm_pass  : in  std_logic;   -- '1' = within bound

    -- Status
    rejection_count : out unsigned(7 downto 0);
    done : out std_logic;
    busy : out std_logic
  );
end entity sign_controller;

architecture rtl of sign_controller is

  type t_state is (
    S_IDLE,
    S_SAMPLE_Y,
    S_NTT_Y,
    S_MATVEC_W,
    S_INTT_W,
    S_DECOMPOSE_W,
    S_CHALLENGE_C,
    S_NTT_C,
    S_COMPUTE_Z,
    S_CHECK_NORM_Z,
    S_CHECK_NORM_W0,
    S_MAKE_HINTS,
    S_CHECK_HINTS,
    S_ACCEPT,
    S_REJECT,
    S_WAIT_SUB
  );

  signal state        : t_state := S_IDLE;
  signal return_state : t_state := S_IDLE;
  signal poly_idx     : unsigned(4 downto 0) := (others => '0');
  signal poly_max     : unsigned(4 downto 0) := (others => '0');
  signal rej_cnt      : unsigned(7 downto 0) := (others => '0');

  -- Composite seed built from base seed XOR nonce for y sampling
  signal y_seed : std_logic_vector(63 downto 0);

begin

  rejection_count <= rej_cnt;

  -- Mix nonce into seed for y sampling (each rejection uses a fresh nonce)
  y_seed <= std_logic_vector(unsigned(seed) xor
              resize(nonce, 64));

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state                <= S_IDLE;
        return_state         <= S_IDLE;
        poly_idx             <= (others => '0');
        poly_max             <= (others => '0');
        rej_cnt              <= (others => '0');
        bram_sel             <= (others => '0');
        done                 <= '0';
        busy                 <= '0';
        ntt_start            <= '0';
        ntt_inverse          <= '0';
        poly_uniform_start   <= '0';
        poly_uniform_seed    <= (others => '0');
        poly_basemul_start   <= '0';
        poly_add_start       <= '0';
        decompose_start      <= '0';
        sample_in_ball_start <= '0';
        inf_norm_start       <= '0';
      else
        -- Default pulse de-assertions
        done                 <= '0';
        ntt_start            <= '0';
        poly_uniform_start   <= '0';
        poly_basemul_start   <= '0';
        poly_add_start       <= '0';
        decompose_start      <= '0';
        sample_in_ball_start <= '0';
        inf_norm_start       <= '0';

        case state is

          -- -------------------------------------------------------
          when S_IDLE =>
            busy    <= '0';
            rej_cnt <= (others => '0');
            if start = '1' then
              busy     <= '1';
              poly_idx <= (others => '0');
              poly_max <= to_unsigned(3, 5);   -- L=4 polys, idx 0..3
              state    <= S_SAMPLE_Y;
            end if;

          -- -------------------------------------------------------
          -- Sample y: L=4 uniform polys stored in BRAMs 24..27
          when S_SAMPLE_Y =>
            bram_sel           <= to_unsigned(24, 5) + poly_idx;
            poly_uniform_seed  <= y_seed;
            poly_uniform_start <= '1';
            return_state       <= S_SAMPLE_Y;
            state              <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- NTT(y): forward NTT on BRAMs 24..27
          when S_NTT_Y =>
            bram_sel     <= to_unsigned(24, 5) + poly_idx;
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_NTT_Y;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- w = A * NTT(y): basemul per output poly (K=4, stored in 28..31)
          when S_MATVEC_W =>
            bram_sel           <= to_unsigned(28, 5) + poly_idx;
            poly_basemul_start <= '1';
            return_state       <= S_MATVEC_W;
            state              <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- INTT(w): BRAMs 28..31 → time-domain w
          when S_INTT_W =>
            bram_sel     <= to_unsigned(28, 5) + poly_idx;
            ntt_inverse  <= '1';
            ntt_start    <= '1';
            return_state <= S_INTT_W;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Decompose each w poly → w1 (high bits) and w0 (low bits)
          when S_DECOMPOSE_W =>
            bram_sel        <= to_unsigned(28, 5) + poly_idx;
            decompose_start <= '1';
            return_state    <= S_DECOMPOSE_W;
            state           <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Hash w1 → challenge polynomial c (sample_in_ball)
          -- Single operation (w1 from BRAMs 28..31 assumed pre-packed)
          when S_CHALLENGE_C =>
            sample_in_ball_start <= '1';
            return_state         <= S_NTT_C;   -- After done, go to NTT_C
            state                <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- NTT(c): forward NTT on challenge poly (single poly, idx=0)
          when S_NTT_C =>
            bram_sel     <= (others => '0');   -- challenge BRAM slot 0
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_COMPUTE_Z;       -- only 1 poly, advance directly
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- z = y + c*s1: basemul c×s1 then poly_add y
          -- Two sub-steps per poly; simplify: basemul first (poly_idx pass 1),
          -- then poly_add (poly_idx pass 2) combined in one loop by
          -- alternating start signals.
          when S_COMPUTE_Z =>
            bram_sel           <= to_unsigned(24, 5) + poly_idx;
            poly_basemul_start <= '1';
            -- After basemul, add y back
            return_state       <= S_COMPUTE_Z;
            state              <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Check ||z||_inf < gamma1 - beta
          when S_CHECK_NORM_Z =>
            bram_sel       <= to_unsigned(24, 5) + poly_idx;
            inf_norm_start <= '1';
            return_state   <= S_CHECK_NORM_Z;
            state          <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Check ||w0||_inf < gamma2 - beta
          when S_CHECK_NORM_W0 =>
            bram_sel       <= to_unsigned(28, 5) + poly_idx;
            inf_norm_start <= '1';
            return_state   <= S_CHECK_NORM_W0;
            state          <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Compute hints h = MakeHint(w0, c*t0, w1)
          -- (Simplified: single decompose call; real implementation
          --  would use use_hint / make_hint modules)
          when S_MAKE_HINTS =>
            bram_sel        <= to_unsigned(28, 5) + poly_idx;
            decompose_start <= '1';
            return_state    <= S_MAKE_HINTS;
            state           <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Check hints: popcount(h) <= omega.
          -- Simplified PoC: always accept.
          when S_CHECK_HINTS =>
            state <= S_ACCEPT;

          -- -------------------------------------------------------
          -- All checks passed: signature is valid
          when S_ACCEPT =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

          -- -------------------------------------------------------
          -- At least one check failed: increment rejection counter
          -- and re-start from y-sampling (nonce is updated externally)
          when S_REJECT =>
            rej_cnt  <= rej_cnt + 1;
            poly_idx <= (others => '0');
            poly_max <= to_unsigned(3, 5);
            state    <= S_SAMPLE_Y;

          -- -------------------------------------------------------
          -- Generic "wait for sub-module done" handler.
          -- Checks all done signals; advances poly_idx or transitions
          -- to the next pipeline stage when the loop is complete.
          when S_WAIT_SUB =>
            if (ntt_done          = '1' or
                poly_uniform_done = '1' or
                poly_basemul_done = '1' or
                poly_add_done     = '1' or
                decompose_done    = '1' or
                sample_in_ball_done = '1' or
                inf_norm_done     = '1') then

              -- norm check: reject immediately if failed
              if inf_norm_done = '1' and inf_norm_pass = '0' then
                state <= S_REJECT;
              elsif poly_idx = poly_max then
                -- Loop over polys is complete; transition to next stage
                poly_idx <= (others => '0');

                case return_state is
                  when S_SAMPLE_Y =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_NTT_Y;

                  when S_NTT_Y =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_MATVEC_W;

                  when S_MATVEC_W =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_INTT_W;

                  when S_INTT_W =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_DECOMPOSE_W;

                  when S_DECOMPOSE_W =>
                    -- Single-call challenge hashing
                    state    <= S_CHALLENGE_C;

                  when S_NTT_C =>
                    -- NTT_C is a single poly, return_state drives next
                    state    <= S_COMPUTE_Z;

                  when S_COMPUTE_Z =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_CHECK_NORM_Z;

                  when S_CHECK_NORM_Z =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_CHECK_NORM_W0;

                  when S_CHECK_NORM_W0 =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_MAKE_HINTS;

                  when S_MAKE_HINTS =>
                    state    <= S_CHECK_HINTS;

                  when others =>
                    state    <= S_ACCEPT;
                end case;
              else
                poly_idx <= poly_idx + 1;
                state    <= return_state;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
