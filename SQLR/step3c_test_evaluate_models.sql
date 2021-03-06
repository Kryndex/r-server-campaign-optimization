/****** Stored Procedure to test and evaluate the models trained in step 3-b) ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

DROP PROCEDURE IF EXISTS [dbo].[test_evaluate_models]
GO

CREATE PROCEDURE [test_evaluate_models] @modelrf varchar(20),
		             @modelbtree varchar(20),
		             @connectionString varchar(300)
AS 
BEGIN

	DROP TABLE IF EXISTS Best_Model
	CREATE TABLE Best_Model (Best_Model varchar(10))

/* 	Test the models on CM_AD_Test.  */
	DECLARE @model_rf varbinary(max) = (select model from Campaign_Models where model_name = @modelrf);
	DECLARE @model_btree varbinary(max) = (select model from Campaign_Models where model_name = @modelbtree);
	INSERT INTO Best_Model
	EXECUTE sp_execute_external_script @language = N'R',
     					   @script = N' 

##########################################################################################################################################
##	Specify the types of the features before the testing
##########################################################################################################################################
# Names of numeric variables: 
#numeric <- c("No_Of_Dependents", "No_Of_Children", "Household_Size", "No_Of_People_Covered", "Premium", "Net_Amt_Insured",
#			  "SMS_Count", "Email_Count", "Call_Count")

# Get the variables names, types and levels for factors.
CM_AD_N <- RxSqlServerData(table = "CM_AD_N", connectionString = connection_string, stringsAsFactors = T)
column_info <- rxCreateColInfo(CM_AD_N)

##########################################################################################################################################
##	Point to the testing set and use the column_info list to specify the types of the features.
##########################################################################################################################################
CM_AD_Test <- RxSqlServerData(  
  sqlQuery = "SELECT *   
              FROM CM_AD_N 
              WHERE Lead_Id NOT IN (SELECT Lead_Id from Train_Id)",
  connectionString = connection_string, colInfo = column_info)

##########################################################################################################################################
## Model evaluation metrics
##########################################################################################################################################
evaluate_model <- function(observed, predicted_probability, threshold) { 
  
  # Given the observed labels and the predicted probability, determine the AUC.
  data <- data.frame(observed, predicted_probability)
  data$observed <- as.numeric(as.character(data$observed))
  ROC <- rxRoc(actualVarName = "observed", predVarNames = "predicted_probability", data = data, numBreaks = 1000)
  auc <- rxAuc(ROC)
  
  # Given the predicted probability and the threshold, determine the binary prediction.
  predicted <- ifelse(predicted_probability > threshold, 1, 0) 
  predicted <- factor(predicted, levels = c(0, 1)) 
  
  # Build the corresponding Confusion Matrix, then compute the Accuracy, Precision, Recall, and F-Score.
  confusion <- table(observed, predicted) 
  print(confusion) 
  tp <- confusion[1, 1] 
  fn <- confusion[1, 2] 
  fp <- confusion[2, 1] 
  tn <- confusion[2, 2] 
  accuracy <- (tp + tn) / (tp + fn + fp + tn) 
  precision <- tp / (tp + fp) 
  recall <- tp / (tp + fn) 
  fscore <- 2 * (precision * recall) / (precision + recall) 
  
  # Return the computed metrics.
  metrics <- c("Accuracy" = accuracy, 
                "Precision" = precision, 
                "Recall" = recall, 
                "F-Score" = fscore,
                "AUC" = auc) 
  return(metrics) 
} 
##########################################################################################################################################
## Random forest scoring
##########################################################################################################################################
# Prediction on the testing set.
forest_model <- unserialize(forest_model)
forest_prediction  <-  RxSqlServerData(table = "Forest_Prediction ", connectionString = connection_string, stringsAsFactors = T,
				       colInfo = column_info)
rxPredict(modelObject = forest_model,
	      data = CM_AD_Test,
		  outData = forest_prediction, 
		  type = "prob",
          extraVarsToWrite = c("Conversion_Flag"),
		  overwrite = TRUE)

# Importing the predictions to evaluate the metrics. 
forest_prediction <- rxImport(forest_prediction)
threshold <- median(forest_prediction$`1_prob`)
forest_metrics <- evaluate_model(observed = forest_prediction$Conversion_Flag,
                                 predicted_probability = forest_prediction$`1_prob`,
				 threshold = threshold)

##########################################################################################################################################
## Boosted tree scoring
##########################################################################################################################################
# Prediction on the testing set.
boosted_model <- unserialize(boosted_model)
boosted_prediction <-  RxSqlServerData(table = "Boosted_Prediction ", connectionString = connection_string, stringsAsFactors = T,
				       colInfo = column_info)
rxPredict(modelObject = boosted_model,
          data = CM_AD_Test,
		  outData = boosted_prediction, 
          type = "prob",
		  extraVarsToWrite = c("Conversion_Flag"),
          overwrite = TRUE)

# Importing the predictions to evaluate the metrics.
boosted_prediction <- rxImport(boosted_prediction)
threshold <- median(boosted_prediction$`1_prob`)
boosted_metrics <- evaluate_model(observed = boosted_prediction$Conversion_Flag,
                                  predicted_probability = boosted_prediction$`1_prob`,
				  threshold = threshold)

##########################################################################################################################################
## Combine metrics and write to SQL. Compute Context is kept to Local to export data. 
##########################################################################################################################################
metrics_df <- rbind(forest_metrics, boosted_metrics)
metrics_df <- as.data.frame(metrics_df)
rownames(metrics_df) <- NULL
Algorithms <- c("Random Forest",
                "Boosted Decision Tree")
metrics_df <- cbind(Algorithms, metrics_df)

metrics_table <- RxSqlServerData(table = "Campaign_Metrics",
                                 connectionString = connection_string)
rxDataStep(inData = metrics_df,
           outFile = metrics_table,
           overwrite = TRUE)
##########################################################################################################################################
## Select the best model based on AUC
##########################################################################################################################################
OutputDataSet <- data.frame(ifelse(forest_metrics[5] >= boosted_metrics[5], "RF", "GBT"))		 		   	   	   
	   '
, @params = N'@forest_model varbinary(max), @boosted_model varbinary(max), @connection_string varchar(300)'
, @forest_model = @model_rf
, @boosted_model = @model_btree
, @connection_string = @connectionString

;
END
GO

