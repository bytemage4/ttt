# Notes on Spring Boot 4.0 release

https://spring.io/blog/2025/11/20/spring-boot-4-0-0-available-now



# Alternatives to REST Assured

## What's REST Assured

REST Assured is a Java library for testing RESTful APIs. It simplifies writing tests for HTTP endpoints by providing a fluent, expressive API for making requests and asserting responses—without needing to manually handle HTTP clients or JSON parsing.

```java
given()
    .baseUri("https://api.example.com")
    .header("Authorization", "Bearer token")
.when()
    .get("/users/123")
.then()
    .statusCode(200)
    .body("name", equalTo("Alice"));
```

## Viable alternatives for REST testing

### WebTestClient

Why it matches Rest Assured: It features a modern, fluent API (chaining methods) that looks and feels very similar to Rest Assured.

Versatility: Although originally built for reactive apps (WebFlux), it works perfectly for standard Servlet-based (blocking) Spring Boot applications.

Assertions: It has powerful built-in assertions for status, headers, and bodies (using JSONPath or library integration).

### Groovy + Spock

- Groovy 4.0+ supports JDK 21 and 25
- Spock 2.4 (Spock 2.4-M1 or higher) is designed to work with Groovy 4 and Java 21+
- Spock is often considered superior for Data-Driven Testing

```java
given().param("id", 1)
       .when().get("/users")
       .then().body("name", equalTo("Alice"));
```

```groovy
def "should return user details"() {
    when: "the user API is called"
    def response = restTemplate.getForEntity("/users/{id}", String, id)

    then: "the name is correct"
    response.statusCode == OK
    response.body.name == expectedName

    where: "we use these inputs"
    id | expectedName
    1  | "Alice"
    2  | "Bob"
}
```

WebTestClient

```java
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.reactive.server.WebTestClient;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UserApiTest {

    @Autowired
    private WebTestClient webTestClient;

    @Test
    void shouldReturnUserDetails() {
        // Define test data
        int userId = 1;
        String expectedName = "Alice";

        webTestClient
            .get()
            .uri("/users/{id}", userId)  // Clean URI variable expansion
            .exchange()                  // Executes the request
            .expectStatus().isOk()       // Assert Status 200
            .expectHeader().contentType("application/json")
            // JSONPath assertions (Native support)
            .expectBody()
            .jsonPath("$.name").isEqualTo(expectedName)
            .jsonPath("$.id").isEqualTo(userId);
    }
}
```

WebTestClient with AssertJ

```java
import static org.assertj.core.api.Assertions.assertThat;
// ... inside the test method

webTestClient
    .get()
    .uri("/users/{id}", 1)
    .exchange()
    .expectStatus().isOk()
    .expectBody(UserDto.class) // Deserialize response directly to POJO
    .consumeWith(result -> {
        UserDto user = result.getResponseBody();
        
        // Now you are in full AssertJ mode
        assertThat(user).isNotNull();
        assertThat(user.getName()).startsWith("Al").isEqualTo("Alice");
    });
```

### Quick summary

| Feature    | Rest Assured                     | TestRestTemplate             | WebTestClient                 | Groovy + Spock                            |
|------------|----------------------------------|------------------------------|-------------------------------|-------------------------------------------|
| Style      | Fluent, BDD (Given/When/Then)    | Standard Java Object         | Fluent, Chained               | Specification-based BDD (given/when/then) |
| Origin     | Third-party library              | Native Spring Framework      | Native Spring Framework       | Groovy ecosystem (Spock Framework)        |
| Assertions | Built-in (Hamcrest/AssertJ)      | Manual (AssertJ/JUnit)       | Built-in (JSONPath, matchers) | Built-in expressive matchers & conditions |
| Best For   | Any Java project needing rich    | Legacy Spring apps or simple | Spring Boot apps needing      | Highly readable, expressive tests; API    |
|            | HTTP testing                     | integration tests            | reactive tests (but not only) | client & behavior specifications          |

### Not considering

RestClient, TestRestTemplate

