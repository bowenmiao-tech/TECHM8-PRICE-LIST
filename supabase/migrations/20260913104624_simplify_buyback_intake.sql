-- Preserve the current acquisition function and its store authorization.
DO $migration$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef('public.create_pos_used_device_acquisition(text,jsonb)'::regprocedure);
  IF position('if intake_photo_count < 3 then' in definition) = 0 THEN
    RAISE EXCEPTION 'Expected acquisition photo gate was not found';
  END IF;
  definition := replace(definition, 'if intake_photo_count < 3 then', 'if intake_photo_count < 1 then');
  definition := replace(definition, 'At least three intake photos are required', 'At least one intake photo is required');
  EXECUTE definition;
END
$migration$;
COMMENT ON FUNCTION public.create_pos_used_device_acquisition(text,jsonb) IS
  'POS buyback intake: store-authorized purchase with at least one intake photo, claimed atomically with the acquisition; starts in inspection.';
