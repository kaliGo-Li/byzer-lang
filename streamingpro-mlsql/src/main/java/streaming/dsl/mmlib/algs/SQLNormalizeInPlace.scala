/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package streaming.dsl.mmlib.algs

import org.apache.spark.ml.linalg.Vectors
import org.apache.spark.ml.param.Param
import org.apache.spark.sql.expressions.UserDefinedFunction
import org.apache.spark.sql.types.{ArrayType, DoubleType}
import org.apache.spark.sql.{DataFrame, MLSQLUtils, SaveMode, SparkSession}
import streaming.dsl.mmlib.SQLAlg
import streaming.dsl.mmlib.algs.MetaConst._
import streaming.dsl.mmlib.algs.feature.DoubleFeature
import streaming.dsl.mmlib.algs.meta.ScaleMeta
import streaming.dsl.mmlib.algs.param.BaseParams
import tech.mlsql.common.form.{Extra, FormParams, KV, Select, Text}

/**
 * Created by allwefantasy on 24/5/2018.
 */
class SQLNormalizeInPlace(override val uid: String) extends SQLAlg with Functions with BaseParams {
  def this() = this(BaseParams.randomUID())

  def internal_train(df: DataFrame, params: Map[String, String]) = {
    val path = params("path")
    val metaPath = getMetaPath(path)
    saveTraningParams(df.sparkSession, params, metaPath)
    val inputCols = params.getOrElse(this.inputCols.name, "").split(",")
    val method = params.getOrElse(this.method.name, "standard")
    val removeOutlierValue = params.getOrElse(this.removeOutlierValue.name, "false").toBoolean
    require(!inputCols.isEmpty, "inputCols is required when use SQLScalerInPlace")
    var newDF = df
    if (removeOutlierValue) {
      newDF = DoubleFeature.killOutlierValue(df, metaPath, inputCols)
    }
    newDF = DoubleFeature.normalize(df, metaPath, inputCols, method, params)
    newDF
  }

  override def train(df: DataFrame, path: String, params: Map[String, String]): DataFrame = {
    val newDF = internal_train(df, params + ("path" -> path))
    newDF.write.mode(SaveMode.Overwrite).parquet(getDataPath(path))
    emptyDataFrame()(df)
  }

  override def load(spark: SparkSession, _path: String, params: Map[String, String]): Any = {
    //load train params
    val path = getMetaPath(_path)
    val (trainParams, df) = getTranningParams(spark, path)
    val inputCols = trainParams.getOrElse(this.inputCols.name, "").split(",").toSeq
    val method = trainParams.getOrElse(this.method.name, "standard")
    val removeOutlierValue = trainParams.getOrElse(this.removeOutlierValue.name, "false").toBoolean

    val scaleFunc = DoubleFeature.getModelNormalizeForPredict(spark, path, inputCols, method, trainParams)

    var meta = ScaleMeta(trainParams, null, scaleFunc)

    if (removeOutlierValue) {
      val removeOutlierValueFunc = DoubleFeature.getModelOutlierValueForPredict(spark, path, inputCols, trainParams)
      meta = meta.copy(removeOutlierValueFunc = removeOutlierValueFunc)
    }
    meta
  }

  override def predict(sparkSession: SparkSession, _model: Any, name: String, params: Map[String, String]): UserDefinedFunction = {

    val meta = _model.asInstanceOf[ScaleMeta]
    val removeOutlierValue = meta.trainParams.getOrElse(this.removeOutlierValue.name, "false").toBoolean
    val inputCols = meta.trainParams.getOrElse(this.inputCols.name, "").split(",").toSeq

    val f = (values: Seq[Double]) => {
      val newValues = if (removeOutlierValue) {
        values.zipWithIndex.map { v =>
          meta.removeOutlierValueFunc(v._1, inputCols(v._2))
        }
      } else values
      meta.scaleFunc(Vectors.dense(newValues.toArray)).toArray
    }
    MLSQLUtils.createUserDefinedFunction(f, ArrayType(DoubleType), Some(Seq(ArrayType(DoubleType))))
  }

  override def explainParams(sparkSession: SparkSession): DataFrame = {
    _explainParams(sparkSession)
  }

  final val inputCols: Param[String] = new Param[String](this, "inputCols", FormParams.toJson(Text(
    name = "inputCols",
    value = "",
    extra = Extra(
      doc =
        """
          |Which text column you want to process.
          |""".stripMargin,
      label = "",
      options = Map(
        "valueType" -> "string"
      )))
  ))

  final val removeOutlierValue: Param[String] = new Param[String](this, "removeOutlierValue", FormParams.toJson(Select(
    name = "removeOutlierValue",
    values= List(),
    extra = Extra(
      doc =
        """
          |Whether to remove outlier values.
          |""".stripMargin,
      label = "",
      options = Map(
        "valueType" -> "string",
        "defaultValue"-> "false",
      )), valueProvider = Option(()=>{
      List(
        KV(Option("removeOutlierValue"),Option("true")),
        KV(Option("removeOutlierValue"),Option("false"))
      )
    }))
  ))

  final val method: Param[String] = new Param[String](this, "method", FormParams.toJson(Select(
    name = "method",
    values= List(),
    extra = Extra(
      doc =
        """
          |Specify the method to do the normalization.
          |""".stripMargin,
      label = "",
      options = Map(
        "valueType" -> "string",
        "defaultValue"-> "standard",
      )), valueProvider = Option(()=>{
      List(
        KV(Option("method"),Option("standard")),
        KV(Option("method"),Option("p-norm"))
      )
    }))
  ))

}
