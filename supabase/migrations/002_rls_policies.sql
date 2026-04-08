-- ============================================================================
-- Row Level Security Policies for Social Memory Feed tables.
-- Identity resolution: auth.uid() → profiles.user_id → profiles.id
-- This matches the existing pattern used by connections table.
-- ============================================================================

-- Enable RLS on all new tables
ALTER TABLE public.encounters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- ── ENCOUNTERS ──────────────────────────────────────────────────────────────

-- Read: either side of the encounter
CREATE POLICY encounters_select ON public.encounters
    FOR SELECT USING (
        profile_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        OR profile_b IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Insert: only the initiating side (profile_a = current user)
CREATE POLICY encounters_insert ON public.encounters
    FOR INSERT WITH CHECK (
        profile_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Update: needed for UPSERT (ON CONFLICT ... DO UPDATE). Same check as insert.
CREATE POLICY encounters_update ON public.encounters
    FOR UPDATE USING (
        profile_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- ── FEED ITEMS ──────────────────────────────────────────────────────────────

-- Read: only your own feed
CREATE POLICY feed_items_select ON public.feed_items
    FOR SELECT USING (
        viewer_profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Insert: only into your own feed
CREATE POLICY feed_items_insert ON public.feed_items
    FOR INSERT WITH CHECK (
        viewer_profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Update: needed for UPSERT. Only your own feed items.
CREATE POLICY feed_items_update ON public.feed_items
    FOR UPDATE USING (
        viewer_profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Delete: allow users to dismiss their own feed items
CREATE POLICY feed_items_delete ON public.feed_items
    FOR DELETE USING (
        viewer_profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- ── CONVERSATIONS ───────────────────────────────────────────────────────────

-- Read: either participant
CREATE POLICY conversations_select ON public.conversations
    FOR SELECT USING (
        participant_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        OR participant_b IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- Insert: current user must be participant_a (the initiator)
CREATE POLICY conversations_insert ON public.conversations
    FOR INSERT WITH CHECK (
        participant_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
    );

-- ── MESSAGES ────────────────────────────────────────────────────────────────

-- Read: messages in conversations the user is part of
CREATE POLICY messages_select ON public.messages
    FOR SELECT USING (
        conversation_id IN (
            SELECT id FROM public.conversations
            WHERE participant_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
               OR participant_b IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        )
    );

-- Insert: sender must be current user AND conversation must include them
CREATE POLICY messages_insert ON public.messages
    FOR INSERT WITH CHECK (
        sender_profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        AND conversation_id IN (
            SELECT id FROM public.conversations
            WHERE participant_a IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
               OR participant_b IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
        )
    );
