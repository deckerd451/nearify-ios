-- ============================================================================
-- Preferred Contact Info on public.profiles
-- SAFE, NON-DESTRUCTIVE: adds optional nullable columns with boolean defaults.
-- ============================================================================

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS public_email text,
    ADD COLUMN IF NOT EXISTS public_phone text,
    ADD COLUMN IF NOT EXISTS linkedin_url text,
    ADD COLUMN IF NOT EXISTS website_url text,
    ADD COLUMN IF NOT EXISTS share_email boolean DEFAULT false,
    ADD COLUMN IF NOT EXISTS share_phone boolean DEFAULT false,
    ADD COLUMN IF NOT EXISTS preferred_contact_method text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'profiles_preferred_contact_method_check'
          AND conrelid = 'public.profiles'::regclass
    ) THEN
        ALTER TABLE public.profiles
            ADD CONSTRAINT profiles_preferred_contact_method_check
            CHECK (
                preferred_contact_method IS NULL
                OR preferred_contact_method IN ('email', 'phone', 'linkedin', 'nearify')
            );
    END IF;
END $$;
