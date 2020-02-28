The repository is used to test the release of the parent pom.xml for open source SonarSource projects. The production parent pom is in https://github.com/SonarSource/parent-oss

Relevant JIRA ticket: https://jira.sonarsource.com/browse/BUILD-792

The final goal is to get rid of https://cix.sonarsource.com/job/parent-oss-qa/ which has been used until now (February 2020) to release the parent pom.xml. All the on-premise Jenkins instances (including CIX) are going to be shut down on the 15th of March 2020, thus it is imperative to migrate the release process.

Although using a personal repo works well to test only the release, the integration with Burgr needs a project under the SonarSource organization.



