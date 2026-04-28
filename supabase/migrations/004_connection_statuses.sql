-- Ensure connections supports approval-gated contact sharing lifecycle statuses.
-- Existing schema uses requester_profile_id/addressee_profile_id as requester/receiver.

ALTER TABLE public.connections
    ADD COLUMN IF NOT EXISTS requester_profile_id uuid,
    ADD COLUMN IF NOT EXISTS addressee_profile_id uuid,
    ADD COLUMN IF NOT EXISTS status text,
    ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

ALTER TABLE public.connections
    DROP CONSTRAINT IF EXISTS connections_status_check;

ALTER TABLE public.connections
    ADD CONSTRAINT connections_status_check
    CHECK (status IN ('suggested', 'pending', 'accepted', 'ignored', 'blocked'));
