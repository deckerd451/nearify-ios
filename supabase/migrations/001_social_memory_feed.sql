-- ============================================================================
-- Social Memory Feed — Supabase Migration
-- SAFE, NON-DESTRUCTIVE: Only creates new tables. No existing tables modified.
-- All profile IDs reference profiles.id (the canonical app identity).
-- Verified against existing schema:
--   - profiles.id exists (used by connections FKs)
--   - events.id exists (used by connections FKs)
--   - connections uses (requester_profile_id, addressee_profile_id, event_id) UNIQUE
-- ============================================================================

-- 1. ENCOUNTERS TABLE
-- Records BLE-derived proximity overlaps between two profiles at an event.
-- Populated by the iOS EncounterService from BLE scanner data.
CREATE TABLE IF NOT EXISTS public.encounters (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        uuid REFERENCES public.events(id),
    profile_a       uuid NOT NULL REFERENCES public.profiles(id),
    profile_b       uuid NOT NULL REFERENCES public.profiles(id),
    first_seen_at   timestamptz DEFAULT now(),
    last_seen_at    timestamptz DEFAULT now(),
    overlap_seconds int DEFAULT 0,
    confidence      float DEFAULT 0.0,

    -- Prevent duplicate encounters per event pair.
    -- Matches the pattern used by connections: pair + event scoping.
    CONSTRAINT unique_encounter_pair UNIQUE (event_id, profile_a, profile_b)
);

CREATE INDEX IF NOT EXISTS idx_encounters_profile_a ON public.encounters(profile_a);
CREATE INDEX IF NOT EXISTS idx_encounters_profile_b ON public.encounters(profile_b);
CREATE INDEX IF NOT EXISTS idx_encounters_event_id  ON public.encounters(event_id);

-- 2. FEED ITEMS TABLE
-- System-generated timeline entries. Never user-created.
-- Types: connection, encounter, suggestion, message
--
-- IMPORTANT: The unique constraint includes event_id because the existing
-- connections table allows the same pair to connect at different events
-- (unique on requester_profile_id, addressee_profile_id, event_id).
-- Feed items must mirror this — one card per connection per event.
CREATE TABLE IF NOT EXISTS public.feed_items (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    viewer_profile_id   uuid NOT NULL REFERENCES public.profiles(id),
    type                text NOT NULL CHECK (type IN ('connection', 'encounter', 'suggestion', 'message')),
    actor_profile_id    uuid REFERENCES public.profiles(id),
    target_profile_id   uuid REFERENCES public.profiles(id),
    event_id            uuid REFERENCES public.events(id),
    created_at          timestamptz DEFAULT now(),
    priority_score      float DEFAULT 50.0,
    metadata            jsonb DEFAULT '{}'::jsonb,

    -- Scoped per event so the same actor can appear in multiple event-specific cards.
    -- For message type (event_id is NULL), this still deduplicates correctly.
    CONSTRAINT unique_feed_item UNIQUE (viewer_profile_id, type, actor_profile_id, event_id)
);

CREATE INDEX IF NOT EXISTS idx_feed_items_viewer   ON public.feed_items(viewer_profile_id);
CREATE INDEX IF NOT EXISTS idx_feed_items_priority ON public.feed_items(priority_score DESC);
CREATE INDEX IF NOT EXISTS idx_feed_items_created  ON public.feed_items(created_at DESC);

-- 3. CONVERSATIONS TABLE
-- Lightweight 1:1 conversations between connected users.
CREATE TABLE IF NOT EXISTS public.conversations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    participant_a   uuid NOT NULL REFERENCES public.profiles(id),
    participant_b   uuid NOT NULL REFERENCES public.profiles(id),
    event_id        uuid REFERENCES public.events(id),
    event_name      text,
    created_at      timestamptz DEFAULT now(),

    -- One conversation per pair (not event-scoped — conversation persists across events)
    CONSTRAINT unique_conversation_pair UNIQUE (participant_a, participant_b)
);

CREATE INDEX IF NOT EXISTS idx_conversations_a ON public.conversations(participant_a);
CREATE INDEX IF NOT EXISTS idx_conversations_b ON public.conversations(participant_b);

-- 4. MESSAGES TABLE
-- Text-only messages within conversations.
CREATE TABLE IF NOT EXISTS public.messages (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id     uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_profile_id   uuid NOT NULL REFERENCES public.profiles(id),
    content             text NOT NULL,
    created_at          timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_created      ON public.messages(created_at);
