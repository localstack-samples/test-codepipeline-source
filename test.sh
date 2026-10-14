#!/usr/bin/env bash
# Run this repository through a LocalStack CodePipeline, as the source of:
# 1. a CodeBuild action using buildspec.yml (Maven build and JUnit tests)
# 2. a CloudFormation action deploying cfn_stack.yaml
# Then check the build artifact holds the jar and the stack created the queue.
# LocalStack only runs V1 pipelines, so the pipeline type is set explicitly.
set -euo pipefail

REPOSITORY=${REPOSITORY:-localstack-samples/test-codepipeline-source}
BRANCH=${BRANCH:-main}
PIPELINE=${PIPELINE:-source-pipeline}
PROJECT=${PROJECT:-message-util-build}
STACK=${STACK:-source-pipeline-stack}
QUEUE=${QUEUE:-source-pipeline-queue}
BUCKET=${BUCKET:-source-pipeline-artifacts}
ROLE_ARN=arn:aws:iam::000000000000:role/source-pipeline-role
MAX_WAIT_SECONDS=${MAX_WAIT_SECONDS:-1800}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Source: $REPOSITORY@$BRANCH"

lstk aws iam create-role --role-name source-pipeline-role --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole", "Principal": {"Service": [
    "codepipeline.amazonaws.com", "codebuild.amazonaws.com", "cloudformation.amazonaws.com"]}}]
}' > /dev/null
lstk aws iam put-role-policy --role-name source-pipeline-role --policy-name source-pipeline \
  --policy-document '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": [
    "s3:*", "codebuild:*", "cloudformation:*", "sqs:*", "logs:*", "iam:PassRole"], "Resource": "*"}]}'

CONNECTION_ARN=$(lstk aws codeconnections create-connection --connection-name source-pipeline \
  --provider-type GitHub --query ConnectionArn --output text)

# No buildspec override, so CodeBuild uses buildspec.yml from the source
lstk aws codebuild create-project --name "$PROJECT" \
  --source type=CODEPIPELINE --artifacts type=CODEPIPELINE \
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:5.0,computeType=BUILD_GENERAL1_SMALL \
  --service-role "$ROLE_ARN" > /dev/null

lstk aws s3 mb "s3://$BUCKET" > /dev/null

cat > "$WORK_DIR/pipeline.json" <<JSON
{
  "name": "$PIPELINE",
  "pipelineType": "V1",
  "roleArn": "$ROLE_ARN",
  "artifactStore": {"type": "S3", "location": "$BUCKET"},
  "stages": [
    {"name": "Source", "actions": [{
      "name": "Source",
      "actionTypeId": {"category": "Source", "owner": "AWS", "provider": "CodeStarSourceConnection", "version": "1"},
      "outputArtifacts": [{"name": "SourceCode"}],
      "configuration": {"ConnectionArn": "$CONNECTION_ARN", "FullRepositoryId": "$REPOSITORY", "BranchName": "$BRANCH"}
    }]},
    {"name": "Build", "actions": [{
      "name": "Build",
      "actionTypeId": {"category": "Build", "owner": "AWS", "provider": "CodeBuild", "version": "1"},
      "inputArtifacts": [{"name": "SourceCode"}],
      "outputArtifacts": [{"name": "BuildOutput"}],
      "configuration": {"ProjectName": "$PROJECT"}
    }]},
    {"name": "Deploy", "actions": [{
      "name": "CreateQueue",
      "actionTypeId": {"category": "Deploy", "owner": "AWS", "provider": "CloudFormation", "version": "1"},
      "roleArn": "$ROLE_ARN",
      "inputArtifacts": [{"name": "SourceCode"}],
      "configuration": {
        "ActionMode": "CREATE_UPDATE",
        "StackName": "$STACK",
        "TemplatePath": "SourceCode::cfn_stack.yaml",
        "RoleArn": "$ROLE_ARN",
        "ParameterOverrides": "{\"QueueName\": \"$QUEUE\"}"
      }
    }]}
  ]
}
JSON
lstk aws codepipeline create-pipeline --pipeline "file://$WORK_DIR/pipeline.json" > /dev/null

status=""
waited=0
until [ "$status" = Succeeded ]; do
  if [[ $status =~ ^(Failed|Stopped|Superseded)$ ]]; then
    echo "Test failed: pipeline execution ended with status $status"
    lstk aws codepipeline get-pipeline-state --name "$PIPELINE"
    exit 1
  fi
  if [ "$status" = None ] && (( waited >= 120 )); then
    echo "Test failed: no pipeline execution started within 120s"
    exit 1
  fi
  if (( waited >= MAX_WAIT_SECONDS )); then
    echo "Test failed: pipeline did not finish within ${MAX_WAIT_SECONDS}s, last status: $status"
    exit 1
  fi
  sleep 10
  waited=$((waited + 10))
  status=$(lstk aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" \
    --query 'pipelineExecutionSummaries[0].status' --output text)
done
echo "PASS: pipeline execution succeeded"

source_revision=$(lstk aws codepipeline list-action-executions --pipeline-name "$PIPELINE" \
  --query "actionExecutionDetails[?actionName=='Source'].output.outputVariables.CommitId | [0]" --output text)
if [ -n "${EXPECTED_COMMIT:-}" ] && [ "$source_revision" != "$EXPECTED_COMMIT" ]; then
  echo "Test failed: the source action fetched $source_revision, expected $EXPECTED_COMMIT"
  exit 1
fi
echo "PASS: the source action fetched commit $source_revision"

read -r out_bucket out_key < <(lstk aws codepipeline list-action-executions --pipeline-name "$PIPELINE" \
  --query "actionExecutionDetails[?actionName=='Build'].output.outputArtifacts[0].s3location | [0].[bucket, key]" \
  --output text)
lstk aws s3 cp "s3://$out_bucket/$out_key" "$WORK_DIR/build-output.zip" > /dev/null
unzip -q -o "$WORK_DIR/build-output.zip" -d "$WORK_DIR/build-output"
JAR="$WORK_DIR/build-output/target/messageUtil-1.0.jar"
if [ ! -f "$JAR" ]; then
  echo "Test failed: the build artifact has no target/messageUtil-1.0.jar"
  unzip -l "$WORK_DIR/build-output.zip"
  exit 1
fi
methods=$(javap -cp "$JAR" MessageUtil)
if [[ "$methods" != *"printMessage()"* || "$methods" != *"salutationMessage()"* ]]; then
  echo "Test failed: MessageUtil in the jar is missing its methods: $methods"
  exit 1
fi
echo "PASS: the build artifact holds messageUtil-1.0.jar with the compiled MessageUtil"

stack_status=$(lstk aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].StackStatus' --output text)
queue_output=$(lstk aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='QueueURL'].OutputValue | [0]" --output text)
queue_url=$(lstk aws sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)
if [ "$stack_status" != CREATE_COMPLETE ] || [ "$queue_output" != "$queue_url" ]; then
  echo "Test failed: stack $STACK is $stack_status with QueueURL '$queue_output', queue URL is '$queue_url'"
  exit 1
fi
echo "PASS: cfn_stack.yaml created queue $QUEUE and output its URL"

echo "Test passed: the repository builds and deploys through CodePipeline"
