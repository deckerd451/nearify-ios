-- Post-Event Release & Reconciliation Tables
-- Run this migration in the Supabase SQL editor.
-- These are NEW tables only — no existing tables are modified.

-- 1. encounter_fragments
-- Stores raw BLE encounter data uploaded from individual devices.
CREATE TABLE IF NOT EXISTS public.encounter_fragments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    uploader_profile_id uuid NOT NULL REFERENCES public.profiles(id),
    event_id uuid,
    peer_ephemeral_id text NOT NULL,
    peer_resolved_profile_id uuid,
    device_encounter_id uuid NOT NULL,
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    duration_seconds int NOT NULL DEFAULT 0,
    avg_rssi float,
    confidence_score float NOT NULL DEFAULT 0.0,
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(uploader_profile_id, device_encounter_id)
);

CREATE INDEX IF NOT EXISTS idx_fragments_uploader ON public.encounter_fragments(uploader_profile_id);
CREATE INDEX IF NOT EXISTS idx_fragments_event ON public.encounter_fragments(event_id) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fragments_peer_prefix ON public.encounter_fragments(peer_ephemeral_id);

-- RLS: users can only insert/select their own fragments
ALTER TABLE public.encounter_fragments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own fragments"
    ON public.encounter_fragments FOR INSERT
    WITH CHECK (
        uploader_profile_id IN (
            SELECT id FROM public.profiles WHERE user_id = auth.uid()
        )
    );

CREATE POLICY "Users can read own fragments"
    ON public.encounter_fragments FOR SELECT
    USING (
        uploader_profile_id IN (
            SELECT id FROM public.profiles WHERE user_id = auth.uid()
        )
    );


-- 2. confirmed_encounters
-- Derived when two fragments from different users match.
-- profile_a is always lexicographically smaller than profile_b.
CREATE TABLE IF NOT EXISTS public.confirmed_encounters (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid,
    profile_a uuid NOT NULL REFERENCES public.profiles(id),
    profile_b uuid NOT NULL REFERENCES public.profiles(id),
    overlap_seconds int NOT NULL DEFAULT 0,
    combined_confidence float NOT NULL DEFAULT 0.0,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(profile_a, profile_b, event_id),
    CHECK (profile_a::text < profile_b::text)
);

CREATE INDEX IF NOT EXISTS idx_confirmed_profile_a ON public.confirmed_encounters(profile_a);
CREATE INDEX IF NOT EXISTS idx_confirmed_profile_b ON public.confirmed_encounters(profile_b);

-- RLS: users can read encounters they are part of
ALTER TABLE public.confirmed_encounters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own confirmed encounters"
    ON public.confirmed_encounters FOR SELECT
    USING (
        profile_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        OR profile_b IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );


-- 3. encounter_releases
-- Tracks each user's intent to release a confirmed encounter.
CREATE TABLE IF NOT EXISTS public.encounter_releases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    confirmed_encounter_id uuid NOT NULL REFERENCES public.confirmed_encounters(id),
    releaser_profile_id uuid NOT NULL REFERENCES public.profiles(id),
    released_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(confirmed_encounter_id, releaser_profile_id)
);

CREATE INDEX IF NOT EXISTS idx_release_confirmed ON public.encounter_releases(confirmed_encounter_id);

-- RLS: users can insert/read their own releases
ALTER TABLE public.encounter_releases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own releases"
    ON public.encounter_releases FOR INSERT
    WITH CHECK (
        releaser_profile_id IN (
            SELECT id FROM public.profiles WHERE user_id = auth.uid()
        )
    );

CREATE POLICY "Users can read own releases"
    ON public.encounter_releases FOR SELECT
    USING (
        releaser_profile_id IN (
            SELECT id FROM public.profiles WHERE user_id = auth.uid()
        )
    );
