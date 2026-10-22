---------------------------------------------------------------------------
-- 05_auditoria_salas.sql  |  Proyecto 2: Licitacion IMAX
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- PARTE 1: RN-18  Una sala con ventas activas no se puede eliminar ni
-- cambiar su distribucion fisica (capacidad, zonas, asientos).
-- "Ventas activas" = boletos reservados o validos de funciones activas
-- que todavia no han terminado.
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_sala_tiene_ventas(p_sala INT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM boleto b
        JOIN funcion f ON f.funcion_id = b.funcion_id
        WHERE f.sala_id = p_sala
          AND f.activa
          AND f.fin > now()
          AND b.estado IN ('reservado', 'valido')
    );
$$;

CREATE OR REPLACE FUNCTION fn_proteger_sala_con_ventas()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_sala INT;
BEGIN
    IF TG_TABLE_NAME = 'sala' THEN
        v_sala := OLD.sala_id;
        -- Cambiar solo el nombre o el estado "activa" no altera la distribucion fisica
        IF TG_OP = 'UPDATE'
           AND NEW.capacidad = OLD.capacidad
           AND NEW.cine_id = OLD.cine_id THEN
            RETURN NEW;
        END IF;
    ELSE
        -- zona y asiento tienen sala_id
        IF TG_OP = 'INSERT' THEN
            v_sala := NEW.sala_id;
        ELSE
            v_sala := OLD.sala_id;
        END IF;
        -- Si el cambio mueve el registro a otra sala, tambien se revisa la sala destino
        IF TG_OP = 'UPDATE' AND NEW.sala_id <> OLD.sala_id
           AND fn_sala_tiene_ventas(NEW.sala_id) THEN
            RAISE EXCEPTION 'RN-18: la sala destino tiene ventas activas y no se puede modificar';
        END IF;
    END IF;

    IF fn_sala_tiene_ventas(v_sala) THEN
        RAISE EXCEPTION 'RN-18: la sala tiene entradas vendidas o reservadas para funciones programadas; no se puede modificar su distribucion';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sala_proteger
BEFORE UPDATE OR DELETE ON sala
FOR EACH ROW EXECUTE FUNCTION fn_proteger_sala_con_ventas();

CREATE TRIGGER trg_zona_proteger
BEFORE UPDATE OR DELETE ON zona
FOR EACH ROW EXECUTE FUNCTION fn_proteger_sala_con_ventas();

CREATE TRIGGER trg_asiento_proteger
BEFORE INSERT OR UPDATE OR DELETE ON asiento
FOR EACH ROW EXECUTE FUNCTION fn_proteger_sala_con_ventas();

---------------------------------------------------------------------------
-- PARTE 2: RN-17 y RN-20  Operaciones manuales de administrador
-- Cada operacion: (1) exige rol administrador, (2) exige un motivo,
-- (3) deja una fila en admin_operacion_audit con usuario, rol, IP y fecha.
---------------------------------------------------------------------------

-- Verifica que el usuario exista, este activo y sea administrador. Devuelve su rol_id.
CREATE OR REPLACE FUNCTION fn_exigir_admin(p_usuario BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol_id SMALLINT;
    v_rol    VARCHAR(30);
BEGIN
    SELECT u.rol_id, r.nombre
      INTO v_rol_id, v_rol
    FROM usuario u
    JOIN rol r ON r.rol_id = u.rol_id
    WHERE u.usuario_id = p_usuario AND u.activo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario % no existe o esta inactivo', p_usuario;
    END IF;
    IF v_rol <> 'administrador' THEN
        RAISE EXCEPTION 'Solo un administrador puede realizar esta operacion';
    END IF;
    RETURN v_rol_id;
END;
$$;

-- Escribe una fila en la bitacora administrativa
CREATE OR REPLACE FUNCTION fn_registrar_auditoria_admin(
    p_usuario  BIGINT,
    p_rol_id   SMALLINT,
    p_accion   VARCHAR,
    p_tabla    VARCHAR,
    p_registro VARCHAR,
    p_detalle  JSONB
)
RETURNS VOID
LANGUAGE sql
AS $$
    INSERT INTO admin_operacion_audit
           (usuario_id, rol_id, ip, accion, tabla_afectada, registro_id, detalle)
    VALUES (p_usuario, p_rol_id, inet_client_addr(), p_accion, p_tabla, p_registro, p_detalle);
$$;

-- ---------------------------------------------------------------------
-- Cambio manual de asiento de un boleto valido
-- Supuesto: el nuevo asiento debe estar en la misma zona (asi el precio no cambia).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cambiar_asiento(
    p_admin         BIGINT,
    p_boleto        BIGINT,
    p_nuevo_asiento BIGINT,
    p_motivo        TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol        SMALLINT;
    v_estado     VARCHAR(10);
    v_funcion    BIGINT;
    v_viejo      BIGINT;
    v_zona_vieja INT;
    v_zona_nueva INT;
BEGIN
    v_rol := fn_exigir_admin(p_admin);

    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;

    SELECT estado, funcion_id, asiento_id
      INTO v_estado, v_funcion, v_viejo
    FROM boleto
    WHERE boleto_id = p_boleto
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boleto % no existe', p_boleto;
    END IF;
    IF v_estado <> 'valido' THEN
        RAISE EXCEPTION 'Solo se puede cambiar el asiento de un boleto valido (estado actual: %)', v_estado;
    END IF;
    IF v_viejo = p_nuevo_asiento THEN
        RAISE EXCEPTION 'El nuevo asiento es el mismo que el actual';
    END IF;

    SELECT zona_id INTO v_zona_vieja FROM asiento WHERE asiento_id = v_viejo;
    SELECT zona_id INTO v_zona_nueva FROM asiento WHERE asiento_id = p_nuevo_asiento;
    IF v_zona_nueva IS DISTINCT FROM v_zona_vieja THEN
        RAISE EXCEPTION 'El nuevo asiento debe estar en la misma zona del asiento actual';
    END IF;

    -- El nuevo asiento debe estar disponible en esa funcion
    UPDATE funcion_asiento
       SET estado = 'vendido'
     WHERE funcion_id = v_funcion
       AND asiento_id = p_nuevo_asiento
       AND estado = 'disponible';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El asiento % no esta disponible en esa funcion', p_nuevo_asiento;
    END IF;

    -- Boletos "reservados" viejos del asiento nuevo son restos de compras abandonadas
    UPDATE boleto SET estado = 'anulado'
     WHERE funcion_id = v_funcion
       AND asiento_id = p_nuevo_asiento
       AND estado = 'reservado';

    -- El asiento anterior queda libre y el boleto apunta al nuevo
    UPDATE funcion_asiento
       SET estado = 'disponible', bloqueado_por = NULL, bloqueado_hasta = NULL
     WHERE funcion_id = v_funcion AND asiento_id = v_viejo;

    UPDATE boleto SET asiento_id = p_nuevo_asiento WHERE boleto_id = p_boleto;

    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    VALUES (v_funcion, v_viejo, p_admin, 'liberado_anulacion'),
           (v_funcion, p_nuevo_asiento, p_admin, 'vendido');

    PERFORM fn_registrar_auditoria_admin(
        p_admin, v_rol, 'cambio_asiento', 'boleto', p_boleto::TEXT,
        jsonb_build_object('asiento_anterior', v_viejo,
                           'asiento_nuevo', p_nuevo_asiento,
                           'motivo', p_motivo));

    RETURN 'ASIENTO CAMBIADO: del asiento ' || v_viejo || ' al asiento ' || p_nuevo_asiento;
END;
$$;

-- ---------------------------------------------------------------------
-- Cortesia: entrada gratuita otorgada por un administrador
-- No genera fila en "pago" (no hay dinero), asi que no cuenta en los
-- reportes de metodos de pago.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_otorgar_cortesia(
    p_admin        BIGINT,
    p_funcion      BIGINT,
    p_asiento      BIGINT,
    p_destinatario BIGINT,
    p_tipo         INT,
    p_motivo       TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol    SMALLINT;
    v_compra BIGINT;
    v_boleto BIGINT;
BEGIN
    v_rol := fn_exigir_admin(p_admin);

    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM usuario WHERE usuario_id = p_destinatario) THEN
        RAISE EXCEPTION 'El destinatario % no existe', p_destinatario;
    END IF;

    PERFORM 1 FROM funcion
    WHERE funcion_id = p_funcion AND activa AND inicio > now();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La funcion no esta disponible';
    END IF;

    UPDATE funcion_asiento
       SET estado = 'vendido'
     WHERE funcion_id = p_funcion
       AND asiento_id = p_asiento
       AND estado = 'disponible';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El asiento % no esta disponible en esa funcion', p_asiento;
    END IF;

    UPDATE boleto SET estado = 'anulado'
     WHERE funcion_id = p_funcion
       AND asiento_id = p_asiento
       AND estado = 'reservado';

    INSERT INTO compra (usuario_id, vendedor_id, canal, estado)
    VALUES (p_destinatario, p_admin, 'taquilla', 'pagada')
    RETURNING compra_id INTO v_compra;

    INSERT INTO boleto (compra_id, funcion_id, asiento_id, tipo_entrada_id,
                        precio_final, codigo_qr, estado, fecha_emision)
    VALUES (v_compra, p_funcion, p_asiento, p_tipo,
            0, gen_random_uuid(), 'valido', now())
    RETURNING boleto_id INTO v_boleto;

    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    VALUES (p_funcion, p_asiento, p_admin, 'vendido');

    INSERT INTO transaccion_log (compra_id, evento, monto, resultado)
    VALUES (v_compra, 'cortesia', 0, 'emitido');

    PERFORM fn_registrar_auditoria_admin(
        p_admin, v_rol, 'cortesia', 'boleto', v_boleto::TEXT,
        jsonb_build_object('funcion_id', p_funcion,
                           'asiento_id', p_asiento,
                           'destinatario', p_destinatario,
                           'motivo', p_motivo));

    RETURN 'CORTESiA OTORGADA: boleto ' || v_boleto || ' para el asiento ' || p_asiento;
END;
$$;

-- ---------------------------------------------------------------------
-- Cambio de precio de una tarifa (configuracion critica, RN-17)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cambiar_tarifa(
    p_admin  BIGINT,
    p_tarifa BIGINT,
    p_precio NUMERIC,
    p_motivo TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol      SMALLINT;
    v_anterior NUMERIC(10,2);
BEGIN
    v_rol := fn_exigir_admin(p_admin);

    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;
    IF p_precio IS NULL OR p_precio < 0 THEN
        RAISE EXCEPTION 'El precio debe ser un numero mayor o igual a cero';
    END IF;

    SELECT precio INTO v_anterior
    FROM tarifa WHERE tarifa_id = p_tarifa
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La tarifa % no existe', p_tarifa;
    END IF;

    UPDATE tarifa SET precio = p_precio WHERE tarifa_id = p_tarifa;

    PERFORM fn_registrar_auditoria_admin(
        p_admin, v_rol, 'cambio_precio', 'tarifa', p_tarifa::TEXT,
        jsonb_build_object('precio_anterior', v_anterior,
                           'precio_nuevo', p_precio,
                           'motivo', p_motivo));

    RETURN 'TARIFA ACTUALIZADA: de ' || v_anterior || ' a ' || p_precio;
END;
$$;

---------------------------------------------------------------------------
-- PARTE 3: RN-20  Bitacoras inalterables
-- Las filas de los 4 logs solo se pueden insertar. Modificarlas o
-- borrarlas da error. (Eliminar una particion vieja con DROP TABLE
-- sigue siendo posible para la retencion de 5 años.)
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_bloquear_modificacion_log()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'RN-20: las bitacoras de auditoria no se pueden modificar ni borrar (tabla %)', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_log_inmutable
BEFORE UPDATE OR DELETE ON transaccion_log
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_modificacion_log();

CREATE TRIGGER trg_log_inmutable
BEFORE UPDATE OR DELETE ON asiento_auditoria_log
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_modificacion_log();

CREATE TRIGGER trg_log_inmutable
BEFORE UPDATE OR DELETE ON acceso_puerta_log
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_modificacion_log();

CREATE TRIGGER trg_log_inmutable
BEFORE UPDATE OR DELETE ON admin_operacion_audit
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_modificacion_log();


