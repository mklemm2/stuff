terraform {
  # Gibt an, welche Terraform-Version mindestens benötigt wird
  required_version = ">= 1.0.0"

  # Gibt an, welche Provider in welchen Versionen vom Modul benötigt werden
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0.0" # Passe dies an deine verwendete AWS-Provider-Version an
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

variable "bucket_name" {
  description = "Der global eindeutige Name des S3-Buckets."
  type        = string
}

variable "assume_role_service" {
  description = "Der AWS-Service, der diese Rolle annehmen darf (z. B. ec2.amazonaws.com oder lambda.amazonaws.com)."
  type        = string
  default     = "ec2.amazonaws.com"
}

variable "tags" {
  description = "Ein Mapping von Tags, die allen Ressourcen zugewiesen werden."
  type        = map(string)
  default     = {
    Terraform = "true"
  }
}

# --- S3 Bucket ---
resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
  tags   = var.tags
}

# (Optional, aber empfohlen) Blockiere öffentliche Zugriffe auf den Bucket
resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM Trust Policy (Wer darf die Rolle annehmen?) ---
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = [var.assume_role_service]
    }
  }
}

# --- IAM Rolle ---
resource "aws_iam_role" "this" {
  name               = "${var.bucket_name}-access-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

# --- IAM Policy Document für S3 Zugriff ---
data "aws_iam_policy_document" "s3_access" {
  # Erlaubnis für Operationen auf Bucket-Ebene
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.this.arn]
  }

  # Erlaubnis für Operationen auf Objekt-Ebene
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
}

# --- IAM Policy ---
resource "aws_iam_policy" "this" {
  name        = "${var.bucket_name}-s3-access-policy"
  description = "Erlaubt Lese- und Schreibzugriff auf den Bucket ${var.bucket_name}"
  policy      = data.aws_iam_policy_document.s3_access.json
  tags        = var.tags
}

# --- Policy an Rolle anhängen ---
resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

output "bucket_id" {
  description = "Der Name (ID) des S3-Buckets"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "Der ARN des S3-Buckets"
  value       = aws_s3_bucket.this.arn
}

output "iam_role_name" {
  description = "Der Name der erstellten IAM-Rolle"
  value       = aws_iam_role.this.name
}

output "iam_role_arn" {
  description = "Der ARN der erstellten IAM-Rolle"
  value       = aws_iam_role.this.arn
}

output "iam_policy_arn" {
  description = "Der ARN der erstellten S3-Zugriffs-Policy"
  value       = aws_iam_policy.this.arn
}
