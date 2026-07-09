-- ============================================================
-- Securely Hello — Initial Database Schema
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- 1. USERS TABLE (public profile + public keys)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url TEXT,
  public_signing_key TEXT NOT NULL,       -- Ed25519 public key (Base64)
  public_encryption_key TEXT NOT NULL,    -- X25519 public key (Base64)
  is_online BOOLEAN NOT NULL DEFAULT false,
  last_seen TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for username search
CREATE INDEX idx_users_username ON public.users(username);
CREATE INDEX idx_users_is_online ON public.users(is_online);

-- RLS
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Anyone authenticated can read public profiles (for contact search)
CREATE POLICY "Public profiles are viewable by authenticated users"
  ON public.users FOR SELECT
  TO authenticated
  USING (true);

-- Users can only insert their own profile
CREATE POLICY "Users can insert own profile"
  ON public.users FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = id);

-- Users can only update their own profile
CREATE POLICY "Users can update own profile"
  ON public.users FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Users can only delete their own profile
CREATE POLICY "Users can delete own profile"
  ON public.users FOR DELETE
  TO authenticated
  USING (auth.uid() = id);

-- ============================================================
-- 2. CONTACTS TABLE (per-user contact list)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  contact_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  nickname TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, contact_user_id)
);

CREATE INDEX idx_contacts_user_id ON public.contacts(user_id);
CREATE INDEX idx_contacts_contact_user_id ON public.contacts(contact_user_id);

-- RLS
ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;

-- Users can only see their own contacts
CREATE POLICY "Users can view own contacts"
  ON public.contacts FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Users can only add contacts for themselves
CREATE POLICY "Users can insert own contacts"
  ON public.contacts FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Users can update their own contacts (e.g., nickname)
CREATE POLICY "Users can update own contacts"
  ON public.contacts FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Users can delete their own contacts
CREATE POLICY "Users can delete own contacts"
  ON public.contacts FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- ============================================================
-- 3. SIGNALING SESSIONS (WebRTC SDP offer/answer relay)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.signaling_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  callee_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  sdp_offer TEXT,
  sdp_answer TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'answered', 'completed', 'expired')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_signaling_caller ON public.signaling_sessions(caller_id);
CREATE INDEX idx_signaling_callee ON public.signaling_sessions(callee_id);
CREATE INDEX idx_signaling_status ON public.signaling_sessions(status);

-- RLS
ALTER TABLE public.signaling_sessions ENABLE ROW LEVEL SECURITY;

-- Both caller and callee can view their sessions
CREATE POLICY "Participants can view signaling sessions"
  ON public.signaling_sessions FOR SELECT
  TO authenticated
  USING (auth.uid() = caller_id OR auth.uid() = callee_id);

-- Only the caller can create a session
CREATE POLICY "Callers can create signaling sessions"
  ON public.signaling_sessions FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = caller_id);

-- Both participants can update (callee sets answer, caller marks complete)
CREATE POLICY "Participants can update signaling sessions"
  ON public.signaling_sessions FOR UPDATE
  TO authenticated
  USING (auth.uid() = caller_id OR auth.uid() = callee_id);

-- Both participants can delete sessions
CREATE POLICY "Participants can delete signaling sessions"
  ON public.signaling_sessions FOR DELETE
  TO authenticated
  USING (auth.uid() = caller_id OR auth.uid() = callee_id);

-- Enable Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.signaling_sessions;
ALTER TABLE public.signaling_sessions REPLICA IDENTITY FULL;

-- ============================================================
-- 4. ICE CANDIDATES (WebRTC connectivity candidates)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ice_candidates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.signaling_sessions(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  target_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  candidate JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ice_session ON public.ice_candidates(session_id);
CREATE INDEX idx_ice_sender ON public.ice_candidates(sender_id);
CREATE INDEX idx_ice_target ON public.ice_candidates(target_user_id);

-- RLS
ALTER TABLE public.ice_candidates ENABLE ROW LEVEL SECURITY;

-- Both sender and target can view candidates
CREATE POLICY "Participants can view ICE candidates"
  ON public.ice_candidates FOR SELECT
  TO authenticated
  USING (auth.uid() = sender_id OR auth.uid() = target_user_id);

-- Users can insert candidates they send
CREATE POLICY "Users can insert ICE candidates"
  ON public.ice_candidates FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = sender_id);

-- Participants can delete candidates
CREATE POLICY "Participants can delete ICE candidates"
  ON public.ice_candidates FOR DELETE
  TO authenticated
  USING (auth.uid() = sender_id OR auth.uid() = target_user_id);

-- Enable Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.ice_candidates;
ALTER TABLE public.ice_candidates REPLICA IDENTITY FULL;

-- ============================================================
-- 5. RELAY QUEUE (encrypted offline message relay — ephemeral)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.relay_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  encrypted_payload TEXT NOT NULL,  -- NaCl box encrypted, Base64
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours')
);

CREATE INDEX idx_relay_recipient ON public.relay_queue(recipient_id);
CREATE INDEX idx_relay_expires ON public.relay_queue(expires_at);

-- RLS
ALTER TABLE public.relay_queue ENABLE ROW LEVEL SECURITY;

-- Recipients can view messages queued for them
CREATE POLICY "Recipients can view queued messages"
  ON public.relay_queue FOR SELECT
  TO authenticated
  USING (auth.uid() = recipient_id);

-- Senders can insert messages
CREATE POLICY "Senders can insert queued messages"
  ON public.relay_queue FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = sender_id);

-- Recipients can delete messages they've received
CREATE POLICY "Recipients can delete received messages"
  ON public.relay_queue FOR DELETE
  TO authenticated
  USING (auth.uid() = recipient_id);

-- Senders can delete their own queued messages
CREATE POLICY "Senders can delete own queued messages"
  ON public.relay_queue FOR DELETE
  TO authenticated
  USING (auth.uid() = sender_id);

-- ============================================================
-- 6. UTILITY: Auto-update updated_at timestamp
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER signaling_updated_at
  BEFORE UPDATE ON public.signaling_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 7. CLEANUP: Auto-expire old signaling sessions & relay queue
-- ============================================================
-- Run periodically via Supabase cron or pg_cron:
-- SELECT cron.schedule('cleanup-expired', '*/15 * * * *', $$
--   DELETE FROM public.signaling_sessions WHERE status = 'expired' OR created_at < now() - INTERVAL '1 hour';
--   DELETE FROM public.relay_queue WHERE expires_at < now();
-- $$);

-- ============================================================
-- 8. ACCOUNT DELETION (SECURITY DEFINER function)
-- ============================================================
CREATE OR REPLACE FUNCTION delete_own_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- CASCADE on foreign keys handles cleanup of contacts, sessions, etc.
  DELETE FROM auth.users WHERE id = auth.uid();
END;
$$;
