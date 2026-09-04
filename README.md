# CodePipeline Sample Source — Message Utility Java App

This repository is a sample source application used to demonstrate [LocalStack's AWS CodePipeline](https://docs.localstack.cloud/aws/services/codepipeline/) emulation. It showcases a full CI/CD workflow with CodeBuild (Maven build + JUnit tests), CodeDeploy (ECS blue/green deployment), and CloudFormation stack provisioning.

## Overview

The application is a simple Java utility (`MessageUtil`) built with Maven and packaged as a JAR. The pipeline:

1. **Source** — pulls this repository as the pipeline source.
2. **Build** — uses CodeBuild with Amazon Corretto 11 to compile the Maven project and run JUnit tests, producing `target/messageUtil-1.0.jar`.
3. **Deploy** — deploys an nginx-based Docker image (serving `index.html`) to an ECS service via CodeDeploy blue/green deployment.
4. **Provision** — optionally creates an SQS queue via the included CloudFormation template.

## Repository Structure

```bash
.
├── Dockerfile          # nginx image serving index.html
├── appspec.yml         # CodeDeploy AppSpec for ECS blue/green deployment
├── buildspec.yml       # CodeBuild build specification (Java/Maven)
├── cfn_stack.yaml      # CloudFormation template — creates an SQS queue
├── index.html          # Static HTML page served by nginx
├── pom.xml             # Maven project descriptor for Message Utility
└── src/
    ├── main/java/MessageUtil.java       # Java utility class
    └── test/java/TestMessageUtil.java   # JUnit tests
```

## Prerequisites

- A valid [LocalStack for AWS license](https://localstack.cloud/pricing), which provides a [`LOCALSTACK_AUTH_TOKEN`](https://docs.localstack.cloud/aws/getting-started/auth-token/) required to run these samples.
- [Docker](https://docs.docker.com/get-docker/) with access to the Docker socket.
- [`lstk`](https://docs.localstack.cloud/aws/developer-tools/running-localstack/lstk/), installed via `npm install -g @localstack/lstk` or `brew install localstack/tap/lstk`. The AWS CLI is required by `lstk aws`.

```bash
export LOCALSTACK_AUTH_TOKEN=<your-auth-token>
```

## Usage

This repository is intended to be used as the **source stage** of a LocalStack CodePipeline sample. Refer to the parent pipeline repository for end-to-end setup instructions.

When used standalone, you can build the Maven project locally:

```bash
mvn install
```

This compiles `MessageUtil.java`, runs the JUnit tests, and produces `target/messageUtil-1.0.jar`.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
