# An example function as a Lambda container image: AWS's Python base image on public.ecr.aws (not Docker Hub, whose
# rate limit the build's anonymous pulls can hit) has Lambda's Runtime Interface Client, so the image adds the handler.
FROM public.ecr.aws/lambda/python:3.12
COPY app.py ${LAMBDA_TASK_ROOT}/
CMD ["app.handler"]
