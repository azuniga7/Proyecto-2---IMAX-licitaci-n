------------------------------------------------------------------------
-- 02_funciones_triggers.sql  
------------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- Utilidad: leer un parametro numerico de la tabla configuracion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_config_int(p_clave TEXT)
RETURNS INT
LANGUAGE sql STABLE
AS $$
    SELECT valor::INT FROM configuracion WHERE clave = p_clave;
$$;

-- ---------------------------------------------------------------------
-- TRIGGER 1: al crear una funcion, se crea el estado de cada asiento
-- de la sala (todos nacen 'disponible'). Asi el mapa de asientos ya existe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_funcion_crear_asientos()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO funcion_asiento (funcion_id, asiento_id, sala_id)
    SELECT NEW.funcion_id, a.asiento_id, a.sala_id
    FROM asiento a
    WHERE a.sala_id = NEW.sala_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_funcion_crear_asientos
AFTER INSERT ON funcion
FOR EACH ROW
EXECUTE FUNCTION fn_funcion_crear_asientos();

-- ---------------------------------------------------------------------
-- FUNCION: liberar bloqueos vencidos (RN-05)
-- Sin parametros revisa TODOS los asientos; con parametros, solo uno.
-- Devuelve cuantos asientos libero y deja cada liberacion en el log.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_liberar_bloqueos_expirados(
    p_funcion BIGINT DEFAULT NULL,
    p_asiento BIGINT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INT;
BEGIN
    WITH expirados AS (
        SELECT funcion_id, asiento_id, bloqueado_por
        FROM funcion_asiento
        WHERE estado = 'bloqueado'
          AND bloqueado_hasta <= now()
          AND (p_funcion IS NULL OR funcion_id = p_funcion)
          AND (p_asiento IS NULL OR asiento_id = p_asiento)
        FOR UPDATE SKIP LOCKED
    ),
    liberados AS (
        UPDATE funcion_asiento fa
           SET estado = 'disponible',
               bloqueado_por = NULL,
               bloqueado_hasta = NULL
          FROM expirados e
         WHERE fa.funcion_id = e.funcion_id
           AND fa.asiento_id = e.asiento_id
        RETURNING fa.funcion_id, fa.asiento_id, e.bloqueado_por
    )
    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    SELECT funcion_id, asiento_id, bloqueado_por, 'liberado_expiracion'
    FROM liberados;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RETURN v_total;
END;
$$;

-- ---------------------------------------------------------------------
-- FUNCION: bloquear un asiento para un usuario (RN-03, RN-04, RN-05)
-- Devuelve la hora en que vence el bloqueo.
-- Si el asiento no esta disponible lanza una excepcion (la compra se rechaza).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_bloquear_asiento(
    p_funcion BIGINT,
    p_asiento BIGINT,
    p_usuario BIGINT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
AS $$
DECLARE
    v_minutos  INT := fn_config_int('minutos_bloqueo_asiento');
    v_maximo   INT := fn_config_int('max_asientos_por_compra');
    v_hasta    TIMESTAMPTZ;
    v_actuales INT;
BEGIN
    -- RN-01: solo funciones activas y futuras
    PERFORM 1
    FROM funcion
    WHERE funcion_id = p_funcion AND activa AND inicio > now();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La funcion no esta disponible para la venta';
    END IF;

    -- Si el bloqueo anterior de ESTE asiento ya vencio, se libera primero
    PERFORM fn_liberar_bloqueos_expirados(p_funcion, p_asiento);

    -- RN-04: limite de asientos que un usuario puede tener bloqueados
    SELECT count(*) INTO v_actuales
    FROM funcion_asiento
    WHERE funcion_id = p_funcion
      AND estado = 'bloqueado'
      AND bloqueado_por = p_usuario
      AND bloqueado_hasta > now();
    IF v_actuales >= v_maximo THEN
        RAISE EXCEPTION 'Maximo de % asientos por compra', v_maximo;
    END IF;

    v_hasta := now() + make_interval(mins => v_minutos);

    -- Un solo UPDATE atomico: si dos usuarios lo intentan a la vez,
    -- el segundo espera, ve que ya no esta 'disponible' y no actualiza nada.
    UPDATE funcion_asiento
       SET estado = 'bloqueado',
           bloqueado_por = p_usuario,
           bloqueado_hasta = v_hasta
     WHERE funcion_id = p_funcion
       AND asiento_id = p_asiento
       AND estado = 'disponible';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El asiento no esta disponible';
    END IF;

    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    VALUES (p_funcion, p_asiento, p_usuario, 'bloqueado');

    RETURN v_hasta;
END;
$$;
