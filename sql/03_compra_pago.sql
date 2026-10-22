------------------------------------------------------------------
-- 03_compra_pago.sql  |  Proyecto 2: Licitacion IMAX 
------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- FUNCIoN: crear una compra a partir de asientos YA bloqueados
--   p_usuario  : comprador 
--   p_funcion  : funcion elegida
--   p_asientos : arreglo de asientos (deben estar bloqueados por quien compra)
--   p_tipos    : arreglo de tipos de entrada, uno por asiento, en el mismo orden
--   p_vendedor : taquillero; si viene NULL la venta es 'online'
-- Devuelve el compra_id. La compra queda 'pendiente' y los boletos 'reservado'
-- (SIN codigo QR: el QR solo se genera al aprobarse el pago, RN-11).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_crear_compra(
    p_usuario  BIGINT,
    p_funcion  BIGINT,
    p_asientos BIGINT[],
    p_tipos    INT[],
    p_vendedor BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_canal      VARCHAR(10) := CASE WHEN p_vendedor IS NULL THEN 'online' ELSE 'taquilla' END;
    v_bloqueador BIGINT      := COALESCE(p_vendedor, p_usuario);
    v_maximo     INT         := fn_config_int('max_asientos_por_compra');
    v_cargo_unit INT         := COALESCE(fn_config_int('cargo_servicio_por_boleto'), 0);
    v_cantidad   INT         := cardinality(p_asientos);
    v_inicio     TIMESTAMPTZ;
    v_vigentes   INT;
    v_compra     BIGINT;
    v_precio     NUMERIC(10,2);
    v_subtotal   NUMERIC(12,2) := 0;
    v_neto       NUMERIC(12,2);
    v_descuento  NUMERIC(12,2);
    v_promo      promocion%ROWTYPE;
    i            INT;
BEGIN
    -- Validaciones basicas
    IF v_cantidad IS NULL OR v_cantidad = 0
       OR p_tipos IS NULL OR v_cantidad <> cardinality(p_tipos) THEN
        RAISE EXCEPTION 'Debe indicar al menos un asiento y un tipo de entrada por cada asiento';
    END IF;

    -- RN-04: maximo de asientos por compra
    IF v_cantidad > v_maximo THEN
        RAISE EXCEPTION 'Maximo de % asientos por compra', v_maximo;
    END IF;

    IF (SELECT count(DISTINCT x) FROM unnest(p_asientos) AS x) <> v_cantidad THEN
        RAISE EXCEPTION 'Hay asientos repetidos en la compra';
    END IF;

    -- RN-01: funcion activa y futura
    SELECT inicio INTO v_inicio
    FROM funcion
    WHERE funcion_id = p_funcion AND activa AND inicio > now();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La funcion no esta disponible para la venta';
    END IF;

    -- Se bloquean las filas de los asientos (orden fijo para evitar interbloqueos)
    PERFORM 1
    FROM funcion_asiento
    WHERE funcion_id = p_funcion AND asiento_id = ANY(p_asientos)
    ORDER BY asiento_id
    FOR UPDATE;

    -- Todos los asientos deben estar bloqueados por quien compra y con el bloqueo vigente (RN-05)
    SELECT count(*) INTO v_vigentes
    FROM funcion_asiento
    WHERE funcion_id = p_funcion
      AND asiento_id = ANY(p_asientos)
      AND estado = 'bloqueado'
      AND bloqueado_por = v_bloqueador
      AND bloqueado_hasta > now();
    IF v_vigentes <> v_cantidad THEN
        RAISE EXCEPTION 'Todos los asientos deben estar bloqueados por usted y con el bloqueo vigente';
    END IF;

    -- Boletos "reservados" viejos de estos asientos son restos de compras abandonadas
    -- (el bloqueo vencio y el asiento se volvio a bloquear): se anulan.
    WITH viejos AS (
        UPDATE boleto
           SET estado = 'anulado'
         WHERE funcion_id = p_funcion
           AND asiento_id = ANY(p_asientos)
           AND estado = 'reservado'
        RETURNING compra_id
    )
    UPDATE compra c
       SET estado = 'cancelada'
      FROM viejos v
     WHERE c.compra_id = v.compra_id
       AND c.estado = 'pendiente';

    -- Cabecera de la compra
    INSERT INTO compra (usuario_id, vendedor_id, canal)
    VALUES (p_usuario, p_vendedor, v_canal)
    RETURNING compra_id INTO v_compra;

    -- Un boleto por asiento, con el precio de la tarifa (funcion + zona + tipo)
    FOR i IN 1..v_cantidad LOOP
        SELECT t.precio INTO v_precio
        FROM tarifa t
        JOIN asiento a ON a.zona_id = t.zona_id
        WHERE t.funcion_id = p_funcion
          AND a.asiento_id = p_asientos[i]
          AND t.tipo_entrada_id = p_tipos[i];
        IF NOT FOUND THEN
            RAISE EXCEPTION 'No hay tarifa definida para el asiento % y el tipo de entrada %',
                p_asientos[i], p_tipos[i];
        END IF;

        INSERT INTO boleto (compra_id, funcion_id, asiento_id, tipo_entrada_id, precio_final)
        VALUES (v_compra, p_funcion, p_asientos[i], p_tipos[i], v_precio);

        v_subtotal := v_subtotal + v_precio;
    END LOOP;

    -- RN-07: promocion automatica (se aplica la primera vigente que cumpla el dia de la funcion)
    SELECT * INTO v_promo
    FROM promocion p
    WHERE p.activa
      AND current_date BETWEEN p.vigente_desde AND p.vigente_hasta
      AND (p.dia_semana IS NULL OR p.dia_semana = EXTRACT(DOW FROM v_inicio)::INT)
    ORDER BY p.promocion_id
    LIMIT 1;

    IF FOUND THEN
        IF v_promo.tipo = 'porcentaje' THEN
            UPDATE boleto
               SET precio_final = round(precio_final * (100 - v_promo.valor) / 100, 2),
                   promocion_id = v_promo.promocion_id
             WHERE compra_id = v_compra;
        ELSE
            -- 2x1: por cada tipo de entrada, la mitad (hacia abajo) de los boletos mas baratos es gratis
            WITH ranked AS (
                SELECT boleto_id,
                       row_number() OVER (PARTITION BY tipo_entrada_id ORDER BY precio_final, boleto_id) AS rn,
                       count(*)     OVER (PARTITION BY tipo_entrada_id) AS n
                FROM boleto
                WHERE compra_id = v_compra
            )
            UPDATE boleto b
               SET precio_final = 0,
                   promocion_id = v_promo.promocion_id
              FROM ranked r
             WHERE b.boleto_id = r.boleto_id
               AND r.rn <= r.n / 2;
        END IF;
    END IF;

    -- RN-08: total = subtotal - descuento + cargos por servicio
    SELECT COALESCE(sum(precio_final), 0) INTO v_neto
    FROM boleto WHERE compra_id = v_compra;
    v_descuento := v_subtotal - v_neto;

    UPDATE compra
       SET subtotal       = v_subtotal,
           descuento      = v_descuento,
           cargo_servicio = v_cargo_unit * v_cantidad,
           total          = v_subtotal - v_descuento + v_cargo_unit * v_cantidad
     WHERE compra_id = v_compra;

    INSERT INTO transaccion_log (compra_id, evento, monto, resultado)
    SELECT compra_id, 'compra_creada', total, 'pendiente'
    FROM compra WHERE compra_id = v_compra;

    RETURN v_compra;
END;
$$;

-- ---------------------------------------------------------------------
-- FUNCION AUXILIAR: deshacer una compra pendiente
-- Anula los boletos, libera los asientos que aun esten bloqueados por
-- quien compraba y deja la compra en el estado indicado.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_anular_compra_pendiente(
    p_compra        BIGINT,
    p_estado_compra VARCHAR,
    p_evento        VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_bloqueador BIGINT;
BEGIN
    SELECT COALESCE(vendedor_id, usuario_id) INTO v_bloqueador
    FROM compra WHERE compra_id = p_compra;

    WITH liberados AS (
        UPDATE funcion_asiento fa
           SET estado = 'disponible',
               bloqueado_por = NULL,
               bloqueado_hasta = NULL
          FROM boleto b
         WHERE b.compra_id = p_compra
           AND b.estado = 'reservado'
           AND fa.funcion_id = b.funcion_id
           AND fa.asiento_id = b.asiento_id
           AND fa.estado = 'bloqueado'
           AND fa.bloqueado_por = v_bloqueador
        RETURNING fa.funcion_id, fa.asiento_id
    )
    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    SELECT funcion_id, asiento_id, v_bloqueador, p_evento
    FROM liberados;

    UPDATE boleto SET estado = 'anulado'
    WHERE compra_id = p_compra AND estado = 'reservado';

    UPDATE compra SET estado = p_estado_compra
    WHERE compra_id = p_compra;
END;
$$;

-- ---------------------------------------------------------------------
-- FUNCION: pago SIMULADO
--   p_aprobar = TRUE  -> la "pasarela" aprueba: asientos vendidos, boletos con QR
--   p_aprobar = FALSE -> la "pasarela" rechaza: no hay cobro y los asientos se liberan (RN-10)
-- Todo ocurre en UNA sola transaccion (ACID): o cambia todo o no cambia nada.
-- Devuelve un texto con el resultado (la "notificacion" del pago).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pagar_compra(
    p_compra  BIGINT,
    p_metodo  SMALLINT,
    p_aprobar BOOLEAN DEFAULT TRUE
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_compra    compra%ROWTYPE;
    v_n_boletos INT;
    v_n_vigentes INT;
    v_pago      BIGINT;
    v_actor     BIGINT;
BEGIN
    -- Se bloquea la compra para que no se pague dos veces
    SELECT * INTO v_compra FROM compra WHERE compra_id = p_compra FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La compra % no existe', p_compra;
    END IF;
    IF v_compra.estado <> 'pendiente' THEN
        RAISE EXCEPTION 'La compra % ya fue procesada (estado: %)', p_compra, v_compra.estado;
    END IF;

    v_actor := COALESCE(v_compra.vendedor_id, v_compra.usuario_id);

    -- Siguen vigentes los bloqueos de todos los asientos? (RN-05)
    SELECT count(*) INTO v_n_boletos
    FROM boleto WHERE compra_id = p_compra AND estado = 'reservado';

    SELECT count(*) INTO v_n_vigentes
    FROM boleto b
    JOIN funcion_asiento fa
      ON fa.funcion_id = b.funcion_id AND fa.asiento_id = b.asiento_id
    WHERE b.compra_id = p_compra
      AND b.estado = 'reservado'
      AND fa.estado = 'bloqueado'
      AND fa.bloqueado_por = v_actor
      AND fa.bloqueado_hasta > now();

    IF v_n_boletos = 0 OR v_n_vigentes <> v_n_boletos THEN
        PERFORM fn_anular_compra_pendiente(p_compra, 'cancelada', 'liberado_expiracion');
        INSERT INTO transaccion_log (compra_id, evento, monto, resultado)
        VALUES (p_compra, 'compra_expirada', v_compra.total, 'cancelada');
        RETURN 'EXPIRADO: el tiempo de bloqueo vencio. La compra fue cancelada y los asientos liberados.';
    END IF;

    -- Pago rechazado (RN-10)
    IF NOT p_aprobar THEN
        INSERT INTO pago (compra_id, metodo_pago_id, monto, estado, referencia_pasarela)
        VALUES (p_compra, p_metodo, v_compra.total, 'rechazado', 'SIM-RECHAZADO')
        RETURNING pago_id INTO v_pago;

        PERFORM fn_anular_compra_pendiente(p_compra, 'fallida', 'liberado_pago_fallido');

        INSERT INTO transaccion_log (compra_id, pago_id, evento, monto, resultado)
        VALUES (p_compra, v_pago, 'pago_rechazado', v_compra.total, 'rechazado');

        RETURN 'RECHAZADO: el pago no fue aprobado. No se cobro dinero y los asientos fueron liberados.';
    END IF;

    -- Pago aprobado
    INSERT INTO pago (compra_id, metodo_pago_id, monto, estado, referencia_pasarela)
    VALUES (p_compra, p_metodo, v_compra.total, 'aprobado', 'SIM-' || gen_random_uuid()::TEXT)
    RETURNING pago_id INTO v_pago;

    -- Asientos pasan a 'vendido'
    WITH vendidos AS (
        UPDATE funcion_asiento fa
           SET estado = 'vendido',
               bloqueado_por = NULL,
               bloqueado_hasta = NULL
          FROM boleto b
         WHERE b.compra_id = p_compra
           AND fa.funcion_id = b.funcion_id
           AND fa.asiento_id = b.asiento_id
        RETURNING fa.funcion_id, fa.asiento_id
    )
    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    SELECT funcion_id, asiento_id, v_actor, 'vendido'
    FROM vendidos;

    -- Recien ahora se emite el QR unico de cada boleto (RN-11, RN-12)
    UPDATE boleto
       SET estado = 'valido',
           codigo_qr = gen_random_uuid(),
           fecha_emision = now()
     WHERE compra_id = p_compra
       AND estado = 'reservado';

    UPDATE compra SET estado = 'pagada' WHERE compra_id = p_compra;

    INSERT INTO transaccion_log (compra_id, pago_id, evento, monto, resultado)
    VALUES (p_compra, v_pago, 'pago_aprobado', v_compra.total, 'aprobado'),
           (p_compra, v_pago, 'boleto_emitido', v_compra.total, 'emitido');

    RETURN 'APROBADO: pago exitoso. Los boletos con su codigo QR ya estan disponibles.';
END;
$$;
