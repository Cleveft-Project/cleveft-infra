-- ============================================================================
--  Migration 010 — push notifications
--
--  Two pieces, deliberately shaped differently:
--
--    * device_tokens is a table. One student has several devices, tokens are
--      revoked one at a time by the OS, and Expo tells us about a dead one by
--      token rather than by user — all of which is row-shaped.
--
--    * notification_prefs is a column. It is always read whole, always written
--      whole, and only ever by its owner. A table would be five joins to learn
--      what one JSONB read already says.
-- ============================================================================

-- The device a push goes to.
CREATE TABLE IF NOT EXISTS auth.device_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,

    -- Expo's push token, e.g. ExponentPushToken[xxxxxxxx].
    --
    -- UNIQUE across the whole table, not per user, and that is the important
    -- part: the token identifies a *phone*, not an account. Two students who
    -- sign in on the same handset — a borrowed phone, a shared tablet, or one
    -- account signed out and another signed in — would otherwise leave two rows
    -- alive for one device, and the first student would keep receiving pushes
    -- about lectures they can no longer open. Registration moves the token to
    -- whoever signed in last.
    token        VARCHAR(255) UNIQUE NOT NULL,

    platform     VARCHAR(16)  NOT NULL,

    -- Touched on every sign-in and every successful send. Tokens are not
    -- guaranteed to be revoked cleanly when an app is uninstalled, so age is
    -- the only signal that a device is gone for good.
    last_seen_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_device_platform CHECK (platform IN ('ios', 'android', 'web'))
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON auth.device_tokens (user_id);

-- ----------------------------------------------------------------------------
--  Preferences
--
--  Defaults are opinions, so they are worth stating.
--
--    lectureReady   on  — asked for implicitly by recording. Processing happens
--                         after the student has left the hall and put the phone
--                         away; without this they have to keep checking.
--    pathAdopted    on  — rare, and the whole point of sharing a path is
--                         learning that it helped someone.
--    peerRequest    on  — someone is waiting on an answer. A request nobody
--                         hears about expires unanswered, which makes the whole
--                         circle look abandoned.
--    dailyReminder  on  — the one genuinely uninvited notification here, and
--                         the reason a study app gets opened on a day nobody
--                         planned to study. 19:00, off in one tap, and never
--                         sent on a day the student already recorded or
--                         revised — a reminder to do something you have done is
--                         how an app teaches people to ignore it.
--    circleActivity off — the noisiest category and the least load-bearing. On
--                         by default it would be most of the volume and none of
--                         the value.
--    weeklySummary  on  — one message a week.
--
--  Quiet hours are absolute and apply to every category except lectureReady,
--  which the student started themselves and is waiting on.
-- ----------------------------------------------------------------------------
ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS notification_prefs JSONB NOT NULL DEFAULT '{
        "lectureReady": true,
        "pathAdopted": true,
        "peerRequest": true,
        "dailyReminder": true,
        "dailyReminderAt": "19:00",
        "circleActivity": false,
        "weeklySummary": true,
        "quietHoursFrom": "22:00",
        "quietHoursTo": "07:00"
    }'::jsonb;

-- IANA name, e.g. Africa/Accra, captured from the device.
--
-- Stored rather than assumed. A reminder at "19:00" means nothing on the server
-- without it, and defaulting everyone to the university's timezone breaks the
-- moment one student is on exchange or home for the holidays.
ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(64) NOT NULL DEFAULT 'Africa/Accra';
