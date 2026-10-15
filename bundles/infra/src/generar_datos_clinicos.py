"""
Generador de historias clínicas 100% SINTÉTICAS para el sandbox de Lakebase.

- Solo usa PySpark nativo (sin librerías externas): la Free Edition restringe
  el acceso saliente a internet y así evitamos depender de PyPI.
- Ningún dato corresponde a personas reales. Los nombres se combinan al azar y
  los identificadores son códigos internos ficticios (PAC-0000001), no cédulas.
- Escala controlada por parámetros: con los valores por defecto genera
  10.000 pacientes y ~100.000 atenciones con notas de ~2 KB (~200 MB).

Tablas Delta resultantes (catalog.schema.*):
  catalogo_diagnosticos  PK codigo
  pacientes              PK paciente_id
  atenciones             PK atencion_id   (tabla principal, la que expondrá el Data API)
"""

import argparse

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F

SEED = 20261015

NOMBRES = ["Ana", "Luis", "María", "Carlos", "Sofía", "Jorge", "Valentina", "Andrés",
           "Camila", "Diego", "Daniela", "Fernando", "Gabriela", "Javier", "Lucía",
           "Mateo", "Paula", "Ricardo", "Isabel", "Santiago", "Elena", "Tomás"]
APELLIDOS = ["García", "Torres", "Morales", "Vargas", "Castillo", "Mendoza", "Herrera",
             "Guerrero", "Rojas", "Salazar", "Paredes", "Andrade", "Cevallos", "Jaramillo",
             "Zambrano", "Villacís", "Ortiz", "Delgado", "Proaño", "Suárez"]
PROVINCIAS_CIUDADES = [("Pichincha", "Quito"), ("Guayas", "Guayaquil"), ("Azuay", "Cuenca"),
                       ("Manabí", "Portoviejo"), ("Tungurahua", "Ambato"), ("Loja", "Loja"),
                       ("Imbabura", "Ibarra"), ("El Oro", "Machala"), ("Chimborazo", "Riobamba")]
TIPOS_SANGRE = ["O+", "O+", "O+", "A+", "A+", "B+", "AB+", "O-", "A-"]
ASEGURADORAS = ["IESS", "IESS", "Particular", "Seguro privado A", "Seguro privado B", "ISSFA"]
SERVICIOS = ["Medicina general", "Medicina general", "Emergencia", "Pediatría", "Cardiología",
             "Endocrinología", "Ginecología", "Traumatología", "Neumología", "Gastroenterología"]
ESTADOS = ["cerrada", "cerrada", "cerrada", "cerrada", "en_seguimiento", "referida"]

# Pequeño subconjunto de códigos CIE-10 (OMS) para dar realismo
DIAGNOSTICOS = [
    ("J06.9", "Infección aguda de las vías respiratorias superiores, no especificada", "J"),
    ("I10", "Hipertensión esencial (primaria)", "I"),
    ("E11.9", "Diabetes mellitus tipo 2 sin complicaciones", "E"),
    ("K29.7", "Gastritis, no especificada", "K"),
    ("M54.5", "Lumbago no especificado", "M"),
    ("N39.0", "Infección de vías urinarias, sitio no especificado", "N"),
    ("J45.9", "Asma, no especificada", "J"),
    ("A09", "Diarrea y gastroenteritis de presunto origen infeccioso", "A"),
    ("R51", "Cefalea", "R"),
    ("Z00.0", "Examen médico general", "Z"),
    ("E66.9", "Obesidad, no especificada", "E"),
    ("J18.9", "Neumonía, no especificada", "J"),
]

FRASES_NOTA = [
    "Paciente acude por cuadro de evolución de varios días.",
    "Refiere molestias de intensidad moderada que ceden parcialmente con reposo.",
    "Al examen físico se encuentra consciente, orientado y afebril.",
    "Se indican exámenes complementarios y control en dos semanas.",
    "Se explica tratamiento y signos de alarma al paciente y familiar.",
    "Antecedentes personales sin cambios respecto a la última consulta.",
    "Se ajusta dosis de medicación habitual según evolución.",
    "Se recomienda dieta balanceada, hidratación y actividad física moderada.",
]


def elegir(valores, seed):
    """Elige un elemento al azar de una lista de literales."""
    arr = F.array(*[F.lit(v) for v in valores])
    idx = (F.floor(F.rand(seed) * len(valores)) + 1).cast("int")
    return F.element_at(arr, idx)


def escribir(df: DataFrame, tabla: str, comentario: str) -> None:
    (df.write.format("delta").mode("overwrite")
       .option("overwriteSchema", "true").saveAsTable(tabla))
    spark = df.sparkSession
    spark.sql(f"COMMENT ON TABLE {tabla} IS '{comentario}'")
    # CDF no es necesario para el modo SNAPSHOT, pero deja la tabla lista para TRIGGERED/CONTINUOUS
    spark.sql(f"ALTER TABLE {tabla} SET TBLPROPERTIES "
              "('delta.enableChangeDataFeed' = 'true', 'synthetic' = 'true')")
    print(f"OK {tabla}: {spark.table(tabla).count():,} filas")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", required=True)
    p.add_argument("--schema", required=True)
    p.add_argument("--num-pacientes", type=int, default=10_000)
    p.add_argument("--atenciones-por-paciente", type=int, default=10)
    p.add_argument("--nota-bytes", type=int, default=2_000)
    a = p.parse_args()

    spark = SparkSession.builder.getOrCreate()
    base = f"{a.catalog}.{a.schema}"
    total_atenciones = a.num_pacientes * a.atenciones_por_paciente
    print(f"Generando en {base}: {a.num_pacientes:,} pacientes, "
          f"~{total_atenciones:,} atenciones, notas de ~{a.nota_bytes} bytes")

    # 1) Catálogo de diagnósticos
    dx = spark.createDataFrame(DIAGNOSTICOS, "codigo string, descripcion string, capitulo string")
    escribir(dx, f"{base}.catalogo_diagnosticos", "Subconjunto CIE-10. Datos de referencia.")

    # 2) Pacientes
    prov = F.array(*[F.struct(F.lit(pv).alias("provincia"), F.lit(c).alias("ciudad"))
                     for pv, c in PROVINCIAS_CIUDADES])
    pacientes = (
        spark.range(1, a.num_pacientes + 1, numPartitions=max(4, a.num_pacientes // 250_000))
        .withColumn("paciente_id", F.format_string("PAC-%07d", F.col("id")))
        .withColumn("nombres", F.concat_ws(" ", elegir(NOMBRES, SEED + 1), elegir(NOMBRES, SEED + 2)))
        .withColumn("apellidos", F.concat_ws(" ", elegir(APELLIDOS, SEED + 3), elegir(APELLIDOS, SEED + 4)))
        .withColumn("sexo", F.when(F.rand(SEED + 5) < 0.51, "F").otherwise("M"))
        .withColumn("fecha_nacimiento",
                    F.date_sub(F.current_date(), (F.rand(SEED + 6) * 365 * 90).cast("int")))
        .withColumn("_loc", F.element_at(prov, (F.floor(F.rand(SEED + 7) * len(PROVINCIAS_CIUDADES)) + 1).cast("int")))
        .withColumn("provincia", F.col("_loc.provincia"))
        .withColumn("ciudad", F.col("_loc.ciudad"))
        .withColumn("tipo_sangre", elegir(TIPOS_SANGRE, SEED + 8))
        .withColumn("aseguradora", elegir(ASEGURADORAS, SEED + 9))
        .withColumn("fecha_registro",
                    F.date_sub(F.current_date(), (F.rand(SEED + 10) * 365 * 15).cast("int")))
        .drop("id", "_loc")
    )
    escribir(pacientes, f"{base}.pacientes", "Pacientes SINTETICOS. No son personas reales.")

    # 3) Atenciones (tabla principal)
    # Distribución sesgada: pocos pacientes concentran muchas atenciones (pacientes crónicos)
    filler = " ".join(FRASES_NOTA)
    atenciones = (
        spark.range(1, total_atenciones + 1,
                    numPartitions=max(8, total_atenciones // 500_000))
        .withColumnRenamed("id", "atencion_id")
        .withColumn("_pid", (F.pow(F.rand(SEED + 20), F.lit(1.6)) * a.num_pacientes).cast("long") + 1)
        .withColumn("paciente_id", F.format_string("PAC-%07d", F.col("_pid")))
        .withColumn("fecha_atencion",
                    F.timestamp_seconds(F.unix_timestamp(F.current_timestamp())
                                        - (F.rand(SEED + 21) * 86400 * 365 * 10).cast("long")))
        .withColumn("servicio", elegir(SERVICIOS, SEED + 22))
        .withColumn("medico_id", F.format_string("MED-%04d", (F.rand(SEED + 23) * 400).cast("int") + 1))
        .withColumn("diagnostico_codigo", elegir([d[0] for d in DIAGNOSTICOS], SEED + 24))
        .withColumn("presion_sistolica", (F.randn(SEED + 25) * 15 + 122).cast("int"))
        .withColumn("presion_diastolica", (F.randn(SEED + 26) * 10 + 78).cast("int"))
        .withColumn("frecuencia_cardiaca", (F.randn(SEED + 27) * 12 + 76).cast("int"))
        .withColumn("temperatura_c", F.round(F.randn(SEED + 28) * 0.5 + 36.8, 1))
        .withColumn("peso_kg", F.round(F.randn(SEED + 29) * 14 + 70, 1))
        .withColumn("estado", elegir(ESTADOS, SEED + 30))
        # Nota clínica: frases al azar + relleno hasta el tamaño objetivo. Este campo
        # es el que permite simular el "peso" por registro (6 TB / 60M ≈ 100 KB).
        .withColumn("_inicio", F.concat_ws(" ", *[elegir(FRASES_NOTA, SEED + 40 + i) for i in range(4)]))
        .withColumn("nota_clinica",
                    F.substring(
                        F.concat_ws(" ", F.col("_inicio"),
                                    F.format_string("Atención %d.", F.col("atencion_id")),
                                    F.expr(f"repeat('{filler} ', {max(1, a.nota_bytes // len(filler) + 1)})")),
                        1, a.nota_bytes))
        .drop("_pid", "_inicio")
    )
    escribir(atenciones, f"{base}.atenciones",
             "Atenciones clinicas SINTETICAS. Tabla principal expuesta por el Data API.")


if __name__ == "__main__":
    main()
