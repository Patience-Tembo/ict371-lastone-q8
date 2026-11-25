-- ==========================================
-- ICT371 QUESTION 8: Transport Fleet Maintenance
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(20) UNIQUE NOT NULL,
  current_odometer      NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_svc_le_odo CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer NUMERIC(12,2) NOT NULL,
  end_odometer   NUMERIC(12,2) NOT NULL,
  CONSTRAINT chk_trip_order CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service NUMERIC(12,2) NOT NULL,
  flagged_on       DATE NOT NULL
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE v_diff NUMERIC;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_diff
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
  
  -- Return boolean for the 5000-kilometre rule
  RETURN v_diff >= 5000;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
  -- Validate the vehicle
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
  
  IF p_end <= p_start THEN RAISE EXCEPTION 'end_odometer must exceed start_odometer'; END IF;
  
  -- Insert the trip (Note: DO NOT update vehicle odometer here, the trigger does it)
  INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC;
BEGIN
  SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
  
  IF v_current IS NULL THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
  
  -- Verify start matches current
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'start_odometer (%) does not match vehicle current (%)', NEW.start_odometer, v_current;
  END IF;
  
  -- Reject invalid mileage
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage';
  END IF;
  
  -- Update current_odometer exactly once
  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;

-- BEFORE INSERT row trigger on trips
CREATE TRIGGER trg_trips_odometer 
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id, trip_on);
-- EXPLAIN SELECT * FROM trips WHERE vehicle_id=1 AND trip_on BETWEEN '2025-01-01' AND '2025-01-31';

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts() LANGUAGE plpgsql AS $$
BEGIN
  -- Insert or update alerts for due vehicles
  INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;
        
  -- Remove alerts once service makes vehicle no longer due
  DELETE FROM service_alerts sa
  USING vehicles v
  WHERE sa.vehicle_id = v.vehicle_id
    AND (v.current_odometer - v.last_service_odometer) < 5000;
END $$;

-- SELECT cron.schedule('fleet-alerts','0 6 * * 1',$$CALL pr_refresh_service_alerts()$$);

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert 3 vehicles (different service positions)
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('AAA-001', 12000, 10000),  -- 2000 km, not due
 ('BBB-002', 20000, 15000),  -- 5000 km, DUE
 ('CCC-003', 30000, 26000);  -- 4000 km, not due

-- 2. Add trips (this will trigger odometer updates)
CALL pr_record_trip(1, CURRENT_DATE, 12000, 16000);  -- AAA now at 16000 (6000 km since service - DUE)
CALL pr_record_trip(2, CURRENT_DATE, 20000, 22000);  -- BBB now at 22000 (7000 km since service - DUE)
CALL pr_record_trip(3, CURRENT_DATE, 30000, 31000);  -- CCC now at 31000 (5000 km since service - DUE)
CALL pr_record_trip(1, CURRENT_DATE - 1, 16000, 18000); -- AAA now at 18000 (8000 km)
CALL pr_record_trip(3, CURRENT_DATE - 1, 31000, 32000); -- CCC now at 32000 (6000 km)
CALL pr_record_trip(2, CURRENT_DATE - 2, 22000, 23000); -- BBB now at 23000 (8000 km)

-- 3. Check the view
SELECT * FROM v_service_due;

-- 4. Refresh alerts and check
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;