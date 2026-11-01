# Container images for producer and consumer, in-region.
# Nodes pull via AmazonEC2ContainerRegistryReadOnly (attached by the EKS module).
resource "aws_ecr_repository" "app" {
  for_each = toset(["producer", "consumer"])

  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag always means the same image

  # Lets terraform destroy delete the repo even when it still holds images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
