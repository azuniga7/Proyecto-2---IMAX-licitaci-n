--------------------------------------------------------------------------
-- 01_ddl.sql
--------------------------------------------------------------------------

-- Necesaria para la restriccion de no traslape de funciones (EXCLUDE)
CREATE EXTENSION IF NOT EXISTS btree_gist;

--------------------------------------------------------------------------
-- BLOQUE A: Usuarios, roles y configuracion
--------------------------------------------------------------------------

CREATE TABLE rol (
    rol_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre  VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE usuario (
    usuario_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rol_id         SMALLINT     NOT NULL REFERENCES rol(rol_id),
    nombre         VARCHAR(80)  NOT NULL,
    apellido       VARCHAR(80)  NOT NULL,
    correo         VARCHAR(120) NOT NULL UNIQUE,
    password_hash  TEXT         NOT NULL,   -- nunca la contrasena en claro
    activo         BOOLEAN      NOT NULL DEFAULT TRUE,
    fecha_registro TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Parametros que el PDF da solo como ejemplo (RN-04, RN-05, RN-16, RN-19)
CREATE TABLE configuracion (
    clave VARCHAR(50)  PRIMARY KEY,
    valor VARCHAR(100) NOT NULL
);

--------------------------------------------------------------------------
-- BLOQUE B: Cartelera y cines
--------------------------------------------------------------------------

CREATE TABLE clasificacion (
    clasificacion_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo           VARCHAR(10) NOT NULL UNIQUE,
    edad_minima      SMALLINT    NOT NULL CHECK (edad_minima >= 0)
);

CREATE TABLE genero (
    genero_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    VARCHAR(40) NOT NULL UNIQUE
);

-- RN-02: titulo, sinopsis y clasificacion son obligatorios
CREATE TABLE pelicula (
    pelicula_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    titulo           VARCHAR(150) NOT NULL,
    sinopsis         TEXT         NOT NULL,
    duracion_min     SMALLINT     NOT NULL CHECK (duracion_min > 0),
    clasificacion_id SMALLINT     NOT NULL REFERENCES clasificacion(clasificacion_id),
    poster_url       VARCHAR(300),
    activa           BOOLEAN      NOT NULL DEFAULT TRUE
);

-- Relacion N:M pelicula-genero
CREATE TABLE pelicula_genero (
    pelicula_id INT      NOT NULL REFERENCES pelicula(pelicula_id),
    genero_id   SMALLINT NOT NULL REFERENCES genero(genero_id),
    PRIMARY KEY (pelicula_id, genero_id)
);

CREATE TABLE cine (
    cine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    VARCHAR(100) NOT NULL,
    pais      VARCHAR(60)  NOT NULL,
    ciudad    VARCHAR(80)  NOT NULL,
    direccion VARCHAR(200) NOT NULL
);

CREATE TABLE sala (
    sala_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cine_id   INT         NOT NULL REFERENCES cine(cine_id),
    nombre    VARCHAR(50) NOT NULL,
    capacidad INT         NOT NULL CHECK (capacidad > 0),
    activa    BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (cine_id, nombre)
);

CREATE TABLE zona (
    zona_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sala_id INT         NOT NULL REFERENCES sala(sala_id),
    nombre  VARCHAR(40) NOT NULL,           -- platea, palco, VIP, general...
    UNIQUE (sala_id, nombre),
    UNIQUE (zona_id, sala_id)               -- necesaria para la FK compuesta de asiento
);

-- sala_id se repite a proposito: permite UNIQUE (sala_id, fila, numero)
-- y la FK compuesta garantiza que la zona sea de la misma sala.
CREATE TABLE asiento (
    asiento_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sala_id    INT         NOT NULL,
    zona_id    INT         NOT NULL,
    fila       VARCHAR(3)  NOT NULL,
    numero     SMALLINT    NOT NULL CHECK (numero > 0),
    UNIQUE (sala_id, fila, numero),
    UNIQUE (asiento_id, sala_id),           -- para la FK compuesta de funcion_asiento
    FOREIGN KEY (zona_id, sala_id) REFERENCES zona(zona_id, sala_id)
);

--------------------------------------------------------------------------
-- BLOQUE C: Funciones, tarifas, promociones y asientos por funcion
--------------------------------------------------------------------------

CREATE TABLE funcion (
    funcion_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pelicula_id INT         NOT NULL REFERENCES pelicula(pelicula_id),
    sala_id     INT         NOT NULL REFERENCES sala(sala_id),
    inicio      TIMESTAMPTZ NOT NULL,
    fin         TIMESTAMPTZ NOT NULL,       -- incluir aqui el tiempo de limpieza
    activa      BOOLEAN     NOT NULL DEFAULT TRUE,
    CHECK (fin > inicio),
    UNIQUE (funcion_id, sala_id),           -- para la FK compuesta de funcion_asiento
    -- No puede haber dos funciones activas traslapadas en la misma sala
    EXCLUDE USING gist (sala_id WITH =, tstzrange(inicio, fin) WITH &&)
        WHERE (activa)
);

CREATE TABLE tipo_entrada (
    tipo_entrada_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          VARCHAR(40) NOT NULL UNIQUE
);

-- Precio por funcion + zona + tipo de entrada (supuesto de diseno)
CREATE TABLE tarifa (
    tarifa_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    funcion_id      BIGINT        NOT NULL REFERENCES funcion(funcion_id),
    zona_id         INT           NOT NULL REFERENCES zona(zona_id),
    tipo_entrada_id SMALLINT      NOT NULL REFERENCES tipo_entrada(tipo_entrada_id),
    precio          NUMERIC(10,2) NOT NULL CHECK (precio >= 0),
    UNIQUE (funcion_id, zona_id, tipo_entrada_id)
);

CREATE TABLE promocion (
    promocion_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre         VARCHAR(80) NOT NULL,
    tipo           VARCHAR(12) NOT NULL CHECK (tipo IN ('2x1', 'porcentaje')),
    valor          NUMERIC(5,2) CHECK (valor BETWEEN 0 AND 100),
    dia_semana     SMALLINT CHECK (dia_semana BETWEEN 0 AND 6),  -- 0 = domingo; NULL = todos
    vigente_desde  DATE NOT NULL,
    vigente_hasta  DATE NOT NULL,
    activa         BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (vigente_hasta >= vigente_desde),
    CHECK (tipo = '2x1' OR valor IS NOT NULL)
);

-- Estado de cada asiento en cada funcion (RN-03, RN-05).
-- La PK (funcion_id, asiento_id) impide fisicamente duplicar un asiento.
-- sala_id se repite para garantizar que el asiento pertenezca a la sala de la funcion.
CREATE TABLE funcion_asiento (
    funcion_id      BIGINT      NOT NULL,
    asiento_id      BIGINT      NOT NULL,
    sala_id         INT         NOT NULL,
    estado          VARCHAR(12) NOT NULL DEFAULT 'disponible'
                    CHECK (estado IN ('disponible', 'bloqueado', 'vendido')),
    bloqueado_por   BIGINT REFERENCES usuario(usuario_id),
    bloqueado_hasta TIMESTAMPTZ,
    PRIMARY KEY (funcion_id, asiento_id),
    FOREIGN KEY (funcion_id, sala_id) REFERENCES funcion(funcion_id, sala_id),
    FOREIGN KEY (asiento_id, sala_id) REFERENCES asiento(asiento_id, sala_id),
    -- Un asiento bloqueado debe tener dueno y hora de expiracion; los demas no
    CHECK (
        (estado = 'bloqueado' AND bloqueado_por IS NOT NULL AND bloqueado_hasta IS NOT NULL)
        OR
        (estado <> 'bloqueado' AND bloqueado_por IS NULL AND bloqueado_hasta IS NULL)
    )
);

--------------------------------------------------------------------------
-- BLOQUE D: Venta, pagos, boletos y reembolsos
--------------------------------------------------------------------------

CREATE TABLE metodo_pago (
    metodo_pago_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre         VARCHAR(40) NOT NULL UNIQUE
);

CREATE TABLE compra (
    compra_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id      BIGINT REFERENCES usuario(usuario_id),   -- comprador
    vendedor_id     BIGINT REFERENCES usuario(usuario_id),   -- taquillero (venta presencial)
    canal           VARCHAR(10) NOT NULL CHECK (canal IN ('online', 'taquilla')),
    estado          VARCHAR(12) NOT NULL DEFAULT 'pendiente'
                    CHECK (estado IN ('pendiente', 'pagada', 'fallida', 'cancelada')),
    subtotal        NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    descuento       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
    cargo_servicio  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (cargo_servicio >= 0),
    total           NUMERIC(12,2) NOT NULL DEFAULT 0,
    fecha_creacion  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- RN-08: total = subtotal - descuento + cargo por servicio
    CHECK (total = subtotal - descuento + cargo_servicio),
    -- Online requiere comprador; taquilla requiere taquillero
    CHECK (canal = 'taquilla' OR usuario_id IS NOT NULL),
    CHECK (canal = 'online'   OR vendedor_id IS NOT NULL)
);

-- RN-09: NO existen columnas para numero de tarjeta ni CVV.
-- Solo la referencia que devuelve la pasarela (simulada).
CREATE TABLE pago (
    pago_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compra_id           BIGINT NOT NULL UNIQUE REFERENCES compra(compra_id),
    metodo_pago_id      SMALLINT NOT NULL REFERENCES metodo_pago(metodo_pago_id),
    monto               NUMERIC(12,2) NOT NULL CHECK (monto > 0),
    estado              VARCHAR(10) NOT NULL DEFAULT 'pendiente'
                        CHECK (estado IN ('pendiente', 'aprobado', 'rechazado')),
    referencia_pasarela VARCHAR(100),
    fecha               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RN-11: el QR solo existe cuando el boleto esta valido o usado.
-- RN-12: codigo_qr es unico y el boleto va ligado a funcion + asiento.
CREATE TABLE boleto (
    boleto_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compra_id       BIGINT   NOT NULL REFERENCES compra(compra_id),
    funcion_id      BIGINT   NOT NULL,
    asiento_id      BIGINT   NOT NULL,
    tipo_entrada_id SMALLINT NOT NULL REFERENCES tipo_entrada(tipo_entrada_id),
    promocion_id    INT REFERENCES promocion(promocion_id),
    precio_final    NUMERIC(10,2) NOT NULL CHECK (precio_final >= 0),
    codigo_qr       UUID UNIQUE,
    estado          VARCHAR(10) NOT NULL DEFAULT 'reservado'
                    CHECK (estado IN ('reservado', 'valido', 'usado', 'anulado')),
    fecha_emision   TIMESTAMPTZ,
    fecha_uso       TIMESTAMPTZ,
    FOREIGN KEY (funcion_id, asiento_id) REFERENCES funcion_asiento(funcion_id, asiento_id),
    CHECK (estado NOT IN ('valido', 'usado') OR codigo_qr IS NOT NULL),
    CHECK (estado <> 'usado' OR fecha_uso IS NOT NULL)
);

-- Anti doble venta: solo un boleto NO anulado por asiento y funcion
CREATE UNIQUE INDEX uq_boleto_asiento_activo
    ON boleto (funcion_id, asiento_id)
    WHERE estado <> 'anulado';

CREATE TABLE reembolso (
    reembolso_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    boleto_id      BIGINT        NOT NULL REFERENCES boleto(boleto_id),
    monto          NUMERIC(10,2) NOT NULL CHECK (monto > 0),
    motivo         TEXT          NOT NULL,
    forzado        BOOLEAN       NOT NULL DEFAULT FALSE,
    autorizado_por BIGINT        NOT NULL REFERENCES usuario(usuario_id),
    fecha          TIMESTAMPTZ   NOT NULL DEFAULT now()
);

--------------------------------------------------------------------------
-- BLOQUE E: Logs de auditoria (retencion 5 anos), particionados por fecha
-- Sin FK a proposito: escribir logs debe ser rapido y no bloquearse.
-- La PK incluye "fecha" porque PostgreSQL lo exige en tablas particionadas.
--------------------------------------------------------------------------

CREATE TABLE transaccion_log (
    log_id    BIGSERIAL,
    compra_id BIGINT,
    pago_id   BIGINT,
    evento    VARCHAR(30) NOT NULL,        
    monto     NUMERIC(12,2),
    impuesto  NUMERIC(12,2),
    resultado VARCHAR(20),
    fecha     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (log_id, fecha)
) PARTITION BY RANGE (fecha);

CREATE TABLE asiento_auditoria_log (
    log_id     BIGSERIAL,
    funcion_id BIGINT NOT NULL,
    asiento_id BIGINT NOT NULL,
    usuario_id BIGINT,
    evento     VARCHAR(25) NOT NULL
               CHECK (evento IN ('bloqueado', 'liberado_expiracion', 'liberado_pago_fallido',
                                 'liberado_anulacion', 'vendido')),
    fecha      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (log_id, fecha)
) PARTITION BY RANGE (fecha);

CREATE TABLE acceso_puerta_log (
    log_id    BIGSERIAL,
    boleto_id BIGINT,
    codigo_qr UUID,
    puerta    VARCHAR(50) NOT NULL,       
    resultado VARCHAR(25) NOT NULL
              CHECK (resultado IN ('exitoso', 'rechazado_duplicado', 'rechazado_horario',
                                   'rechazado_funcion', 'rechazado_inexistente')),
    fecha     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (log_id, fecha)
) PARTITION BY RANGE (fecha);

CREATE TABLE admin_operacion_audit (
    log_id         BIGSERIAL,
    usuario_id     BIGINT      NOT NULL,
    rol_id         SMALLINT    NOT NULL,
    ip             INET,
    accion         VARCHAR(40) NOT NULL,   
    tabla_afectada VARCHAR(50),
    registro_id    VARCHAR(50),
    detalle        JSONB,
    fecha          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (log_id, fecha)
) PARTITION BY RANGE (fecha);

-- Particiones anuales 2026 a 2031 (cubren 5 anos de retencion)
DO $$
DECLARE
    t TEXT;
    y INT;
BEGIN
    FOREACH t IN ARRAY ARRAY['transaccion_log', 'asiento_auditoria_log',
                             'acceso_puerta_log', 'admin_operacion_audit']
    LOOP
        FOR y IN 2026..2031 LOOP
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                t || '_' || y, t, y || '-01-01', (y + 1) || '-01-01'
            );
        END LOOP;
    END LOOP;
END $$;

--------------------------------------------------------------------------
-- DATOS BASE (catalogos minimos que el sistema necesita para funcionar)
--------------------------------------------------------------------------

INSERT INTO rol (nombre) VALUES
    ('cliente'), ('taquillero'), ('operador_sala'), ('contador'), ('administrador');

-- Valores SUPUESTOS tomados de los ejemplos del PDF; el equipo puede cambiarlos
INSERT INTO configuracion (clave, valor) VALUES
    ('max_asientos_por_compra',   '6'),    -- RN-04 
    ('minutos_bloqueo_asiento',   '2'),    -- RN-05
    ('tolerancia_antes_min',      '30'),   -- RN-16
    ('tolerancia_despues_min',    '15'),   -- RN-16
    ('horas_limite_reembolso',    '2');    -- RN-19

INSERT INTO tipo_entrada (nombre) VALUES
    ('adulto'), ('nino'), ('tercera_edad'), ('estudiante');

INSERT INTO metodo_pago (nombre) VALUES
    ('tarjeta'), ('paypal'), ('billetera_digital'), ('transferencia');
